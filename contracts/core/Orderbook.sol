// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../utils/ordersUtils.sol";
import "../utils/eventUtils.sol";



contract Orderbook {
    using OrderUtils for OrderUtils.Order;
    using OrderUtils for OrderUtils.PriceLevel;

    // State variables
    uint256 public nextOrderId = 1;
    uint256 public nextTradeId = 1;
    uint256 public lastTradedPrice = 0;

    bytes32 public marketHash;
    address public collateralToken; // USDT
    address public indexToken;     // Index token
    address public owner;

    mapping(uint256 => OrderUtils.Order) public orders;
    mapping(address => uint256[]) public userOpenOrders; // User to active order IDs
    mapping(uint256 => uint256[]) public buyPriceLevelOrders;  // Price to buy order IDs
    mapping(uint256 => uint256[]) public sellPriceLevelOrders; // Price to sell order IDs
    mapping(uint256 => OrderUtils.PriceLevel) public buyPriceLevels;  // Buy price levels (descending)
    mapping(uint256 => OrderUtils.PriceLevel) public sellPriceLevels; // Sell price levels (ascending)
    mapping(uint256 => uint256) public buyPriceLevelUsdtVolume; // USDT volume for buy price levels
    mapping(uint256 => uint256) public sellPriceLevelUsdtVolume; // USDT volume for sell price levels

    uint256 public bestBidPrice = 0; // Highest buy price
    uint256 public bestAskPrice = 0; // Lowest sell price

    OrderUtils.Trade[] public trades;

    // Temporary storage for trade results to reduce stack usage
    struct TradeResult {
        uint256 tradeQuantity;
        uint256 tradeUsdt;
    }
    TradeResult private tempTradeResult;

    constructor(bytes32 _marketHash, address _collateralToken, address _indexToken) {
        marketHash = _marketHash;
        collateralToken = _collateralToken;
        indexToken = _indexToken;
        owner = msg.sender;
    }

    // Modifiers
    modifier onlyOrderOwner(uint256 orderId) {
        require(orders[orderId].trader == msg.sender, "Not order owner");
        _;
    }

    modifier validOrder(uint256 orderId) {
        require(orders[orderId].id != 0, "Order does not exist");
        _;
    }

    // Create a new order
    function createOrder(
        OrderUtils.OrderType _orderType,
        OrderUtils.OrderSide _side,
        uint256 _price,
        uint256 _quantityInTokens,
        uint256 _quantityInUsdt
    ) external returns (uint256) {
        // Handle token transfers
        if (_side == OrderUtils.OrderSide.BUY) {
            if (_orderType == OrderUtils.OrderType.MARKET) {
                require(_quantityInUsdt > 0, "Invalid USDT quantity");
                require(IERC20(collateralToken).transferFrom(msg.sender, address(this), _quantityInUsdt), "USDT transfer failed");
            } else {
                require(_price > 0 && _quantityInTokens > 0, "Invalid price or quantity");
                uint256 requiredUsdt = _price * _quantityInTokens;
                require(IERC20(collateralToken).transferFrom(msg.sender, address(this), requiredUsdt), "USDT transfer failed");
                _quantityInUsdt = requiredUsdt;
            }
        } else {
            require(_quantityInTokens > 0, "Invalid token quantity");
            require(IERC20(indexToken).transferFrom(msg.sender, address(this), _quantityInTokens), "Token transfer failed");
        }

        OrderUtils.validateOrderCreation(_orderType, _price, _quantityInTokens);

        uint256 orderId = nextOrderId++;
        orders[orderId] = OrderUtils.Order({
            id: orderId,
            trader: msg.sender,
            orderType: _orderType,
            side: _side,
            price: _orderType == OrderUtils.OrderType.MARKET ? 0 : _price,
            quantityInTokens: _orderType == OrderUtils.OrderType.MARKET && _side == OrderUtils.OrderSide.BUY ? 0 : _quantityInTokens,
            quantityInUsdt: _quantityInUsdt,
            filled: 0,
            status: OrderUtils.OrderStatus.ACTIVE,
            timestamp: block.timestamp,
            nextOrder: 0,
            prevOrder: 0
        });

        userOpenOrders[msg.sender].push(orderId);
        emit EventUtils.OrderCreated(orderId, msg.sender, _orderType, _side, orders[orderId].price, _quantityInTokens);

        if (_orderType == OrderUtils.OrderType.MARKET) {
            _executeMarketOrder(orderId);
        } else {
            _matchLimitOrder(orderId);
            if (orders[orderId].status == OrderUtils.OrderStatus.ACTIVE) {
                _addToOrderbook(orderId);
            }
        }
        return orderId;
    }

    // Cancel an order
    function cancelOrder(uint256 orderId) external onlyOrderOwner(orderId) validOrder(orderId) {
        OrderUtils.Order storage order = orders[orderId];
        require(order.status == OrderUtils.OrderStatus.ACTIVE, "Order not active");

        order.status = OrderUtils.OrderStatus.CANCELLED;
        _removeFromOrderbook(orderId);
        _removeFromUserOpenOrders(orderId);

        uint256 remainingTokens = order.quantityInTokens - order.filled;
        if (order.side == OrderUtils.OrderSide.BUY) {
            uint256 refundUsdt = order.orderType == OrderUtils.OrderType.MARKET ? order.quantityInUsdt : order.price * remainingTokens;
            if (refundUsdt > 0) {
                require(IERC20(collateralToken).transfer(order.trader, refundUsdt), "USDT refund failed");
            }
        } else {
            if (remainingTokens > 0) {
                require(IERC20(indexToken).transfer(order.trader, remainingTokens), "Token refund failed");
            }
        }

        emit EventUtils.OrderCancelled(orderId, msg.sender);
    }

    // Execute a market order
    function _executeMarketOrder(uint256 orderId) internal {
        OrderUtils.Order storage order = orders[orderId];
        uint256 remainingQuantity = order.side == OrderUtils.OrderSide.BUY ? order.quantityInUsdt : order.quantityInTokens - order.filled;

        if (order.side == OrderUtils.OrderSide.BUY) {
            uint256 currentPrice = bestAskPrice;
            while (currentPrice != 0 && remainingQuantity > 0) {
                (remainingQuantity, ) = _matchAtPriceLevel(orderId, currentPrice, remainingQuantity, false);
                currentPrice = sellPriceLevels[currentPrice].nextPrice;
            }
        } else {
            uint256 currentPrice = bestBidPrice;
            while (currentPrice != 0 && remainingQuantity > 0) {
                (remainingQuantity, ) = _matchAtPriceLevel(orderId, currentPrice, remainingQuantity, true);
                currentPrice = buyPriceLevels[currentPrice].prevPrice;
            }
        }

        // Refund remaining collateral
        if (remainingQuantity > 0) {
            if (order.side == OrderUtils.OrderSide.BUY) {
                require(IERC20(collateralToken).transfer(order.trader, remainingQuantity), "USDT refund failed");
                order.quantityInUsdt = order.quantityInUsdt - remainingQuantity;
            } else {
                require(IERC20(indexToken).transfer(order.trader, remainingQuantity), "Token refund failed");
            }
        }

        if (order.isOrderFullyFilled()) {
            order.status = OrderUtils.OrderStatus.FILLED;
            _removeFromUserOpenOrders(orderId);
        }
    }

    // Match limit order
    function _matchLimitOrder(uint256 orderId) internal {
        OrderUtils.Order storage order = orders[orderId];
        uint256 remainingQuantity = order.quantityInTokens - order.filled;

        if (order.side == OrderUtils.OrderSide.BUY) {
            uint256 currentPrice = bestAskPrice;
            while (currentPrice != 0 && remainingQuantity > 0 && currentPrice <= order.price) {
                (remainingQuantity, ) = _matchAtPriceLevel(orderId, currentPrice, remainingQuantity, false);
                currentPrice = sellPriceLevels[currentPrice].nextPrice;
            }
        } else {
            uint256 currentPrice = bestBidPrice;
            while (currentPrice != 0 && remainingQuantity > 0 && currentPrice >= order.price) {
                (remainingQuantity, ) = _matchAtPriceLevel(orderId, currentPrice, remainingQuantity, true);
                currentPrice = buyPriceLevels[currentPrice].prevPrice;
            }
        }

        if (order.isOrderFullyFilled()) {
            order.status = OrderUtils.OrderStatus.FILLED;
            _removeFromUserOpenOrders(orderId);
        }
    }

    // Helper function to process a trade
    function _processTrade(uint256 buyOrderId, uint256 sellOrderId, uint256 maxQuantity) internal {
        (tempTradeResult.tradeQuantity, tempTradeResult.tradeUsdt) = _executeTrade(buyOrderId, sellOrderId, maxQuantity);
    }

    // Match at a specific price
    function _matchAtPriceLevel(uint256 orderId, uint256 price, uint256 maxQuantity, bool matchingWithBuy)
        internal
        returns (uint256, uint256)
    {
        mapping(uint256 => OrderUtils.PriceLevel) storage priceLevels = matchingWithBuy ? buyPriceLevels : sellPriceLevels;
        mapping(uint256 => uint256) storage usdtVolume = matchingWithBuy ? buyPriceLevelUsdtVolume : sellPriceLevelUsdtVolume;

        if (!priceLevels[price].exists) return (maxQuantity, 0);

        mapping(uint256 => uint256[]) storage priceLevelOrders = matchingWithBuy ? buyPriceLevelOrders : sellPriceLevelOrders;
        uint256[] memory orderIds = priceLevelOrders[price]; // Cache in memory
        uint256 remainingQuantity = maxQuantity;
        uint256 usdtSpent = 0;
        bool isBuy = orders[orderId].side == OrderUtils.OrderSide.BUY;

        for (uint256 i = 0; i < orderIds.length && remainingQuantity > 0; i++) {
            uint256 currentOrderId = orderIds[i];
            if (!orders[currentOrderId].isOrderActive() || !orders[orderId].canMatchOrders(orders[currentOrderId])) {
                continue;
            }

            _processTrade(isBuy ? orderId : currentOrderId, isBuy ? currentOrderId : orderId, remainingQuantity);
            uint256 tradeUsdt = tempTradeResult.tradeUsdt;
            remainingQuantity -= tradeUsdt;
            usdtSpent += tradeUsdt;

            uint256 matchedOrderId = isBuy ? currentOrderId : orderId;
            if (orders[matchedOrderId].isOrderFullyFilled()) {
                orders[matchedOrderId].status = OrderUtils.OrderStatus.FILLED;
                _removeFromUserOpenOrders(matchedOrderId);
                _removeOrderFromPriceLevel(matchedOrderId, price, matchingWithBuy);
            }
        }

        if (priceLevels[price].isPriceLevelEmpty()) {
            _removePriceLevel(price, matchingWithBuy ? OrderUtils.OrderSide.BUY : OrderUtils.OrderSide.SELL);
            usdtVolume[price] = 0;
        }

        return (remainingQuantity, usdtSpent);
    }

    // Execute a trade
    function _executeTrade(uint256 buyOrderId, uint256 sellOrderId, uint256 maxQuantity) internal returns (uint256, uint256) {
        OrderUtils.Order storage buyOrder = orders[buyOrderId];
        OrderUtils.Order storage sellOrder = orders[sellOrderId];

        uint256 buyRemaining = buyOrder.quantityInTokens - buyOrder.filled;
        if (buyOrder.orderType == OrderUtils.OrderType.MARKET) {
            buyRemaining = buyOrder.quantityInUsdt / sellOrder.price; // Max tokens affordable
        }
        uint256 sellRemaining = sellOrder.quantityInTokens - sellOrder.filled;
        uint256 tradeQuantity = OrderUtils.min(OrderUtils.min(buyRemaining, sellRemaining), maxQuantity);
        uint256 tradePrice = sellOrder.price;

        uint256 usdtAmount = tradePrice * tradeQuantity;

        if (buyOrder.orderType == OrderUtils.OrderType.MARKET) {
            require(buyOrder.quantityInUsdt >= usdtAmount, "Insufficient USDT");
            buyOrder.quantityInTokens += tradeQuantity;
            buyOrder.quantityInUsdt -= usdtAmount;
            buyOrder.filled += tradeQuantity;
        } else {
            buyOrder.filled += tradeQuantity;
        }
        sellOrder.filled += tradeQuantity;

        // Update price level volumes
        if (buyPriceLevels[buyOrder.price].exists && buyOrder.orderType != OrderUtils.OrderType.MARKET) {
            buyPriceLevels[buyOrder.price].totalVolume -= tradeQuantity;
            buyPriceLevelUsdtVolume[buyOrder.price] -= usdtAmount;
        }
        if (sellPriceLevels[sellOrder.price].exists) {
            sellPriceLevels[sellOrder.price].totalVolume -= tradeQuantity;
            sellPriceLevelUsdtVolume[sellOrder.price] -= usdtAmount;
        }

        // Transfer tokens
        require(IERC20(indexToken).transfer(buyOrder.trader, tradeQuantity), "Token transfer to buyer failed");
        require(IERC20(collateralToken).transfer(sellOrder.trader, usdtAmount), "USDT transfer to seller failed");

        // Create trade record
        trades.push(OrderUtils.Trade({
            id: nextTradeId++,
            buyOrderId: buyOrderId,
            sellOrderId: sellOrderId,
            buyer: buyOrder.trader,
            seller: sellOrder.trader,
            price: tradePrice,
            quantity: tradeQuantity,
            timestamp: block.timestamp
        }));

        _updateLTP(tradePrice);

        emit EventUtils.TradeExecuted(nextTradeId - 1, buyOrderId, sellOrderId, buyOrder.trader, sellOrder.trader, tradePrice, tradeQuantity);
        emit EventUtils.OrderFilled(buyOrderId, tradeQuantity, buyOrder.quantityInTokens - buyOrder.filled);
        emit EventUtils.OrderFilled(sellOrderId, tradeQuantity, sellOrder.quantityInTokens - sellOrder.filled);

        return (tradeQuantity, usdtAmount);
    }

    // Add order to orderbook
    function _addToOrderbook(uint256 orderId) internal {
        OrderUtils.Order storage order = orders[orderId];
        uint256 price = order.price;

        mapping(uint256 => uint256[]) storage priceLevelOrders = order.side == OrderUtils.OrderSide.BUY ? buyPriceLevelOrders : sellPriceLevelOrders;
        mapping(uint256 => OrderUtils.PriceLevel) storage priceLevels = order.side == OrderUtils.OrderSide.BUY ? buyPriceLevels : sellPriceLevels;
        mapping(uint256 => uint256) storage usdtVolume = order.side == OrderUtils.OrderSide.BUY ? buyPriceLevelUsdtVolume : sellPriceLevelUsdtVolume;

        if (!priceLevels[price].exists) {
            _createPriceLevel(price, order.side);
        }

        OrderUtils.PriceLevel storage level = priceLevels[price];
        priceLevelOrders[price].push(orderId);

        if (level.firstOrder == 0) {
            level.firstOrder = orderId;
            level.lastOrder = orderId;
        } else {
            orders[level.lastOrder].nextOrder = orderId;
            orders[orderId].prevOrder = level.lastOrder;
            level.lastOrder = orderId;
        }

        level.totalVolume += order.quantityInTokens - order.filled;
        usdtVolume[price] += order.price * (order.quantityInTokens - order.filled);
    }

    // Create a new price level
    function _createPriceLevel(uint256 price, OrderUtils.OrderSide side) internal {
        mapping(uint256 => OrderUtils.PriceLevel) storage priceLevels = side == OrderUtils.OrderSide.BUY ? buyPriceLevels : sellPriceLevels;

        priceLevels[price] = OrderUtils.PriceLevel({
            price: price,
            firstOrder: 0,
            lastOrder: 0,
            totalVolume: 0,
            nextPrice: 0,
            prevPrice: 0,
            exists: true
        });

        if (side == OrderUtils.OrderSide.BUY) {
            _insertBuyPriceLevel(price);
        } else {
            _insertSellPriceLevel(price);
        }

        emit EventUtils.PriceLevelCreated(price, side);
    }

    // Insert buy price level (descending order)
    function _insertBuyPriceLevel(uint256 price) internal {
        if (bestBidPrice == 0 || price > bestBidPrice) {
            if (bestBidPrice != 0) {
                buyPriceLevels[bestBidPrice].prevPrice = price;
                buyPriceLevels[price].nextPrice = bestBidPrice;
            }
            bestBidPrice = price;
        } else {
            uint256 current = bestBidPrice;
            while (buyPriceLevels[current].nextPrice != 0 && buyPriceLevels[current].nextPrice > price) {
                current = buyPriceLevels[current].nextPrice;
            }

            uint256 next = buyPriceLevels[current].nextPrice;
            buyPriceLevels[current].nextPrice = price;
            buyPriceLevels[price].prevPrice = current;
            buyPriceLevels[price].nextPrice = next;

            if (next != 0) {
                buyPriceLevels[next].prevPrice = price;
            }
        }
    }

    // Insert sell price level (ascending order)
    function _insertSellPriceLevel(uint256 price) internal {
        if (bestAskPrice == 0 || price < bestAskPrice) {
            if (bestAskPrice != 0) {
                sellPriceLevels[bestAskPrice].prevPrice = price;
                sellPriceLevels[price].nextPrice = bestAskPrice;
            }
            bestAskPrice = price;
        } else {
            uint256 current = bestAskPrice;
            while (sellPriceLevels[current].nextPrice != 0 && sellPriceLevels[current].nextPrice < price) {
                current = sellPriceLevels[current].nextPrice;
            }

            uint256 next = sellPriceLevels[current].nextPrice;
            sellPriceLevels[current].nextPrice = price;
            sellPriceLevels[price].prevPrice = current;
            sellPriceLevels[price].nextPrice = next;

            if (next != 0) {
                sellPriceLevels[next].prevPrice = price;
            }
        }
    }

    // Remove order from orderbook
    function _removeFromOrderbook(uint256 orderId) internal {
        OrderUtils.Order storage order = orders[orderId];
        uint256 price = order.price;

        // mapping(uint256 => uint256[]) storage priceLevelOrders = order.side == OrderUtils.OrderSide.BUY ? buyPriceLevelOrders : sellPriceLevelOrders;
        mapping(uint256 => OrderUtils.PriceLevel) storage priceLevels = order.side == OrderUtils.OrderSide.BUY ? buyPriceLevels : sellPriceLevels;
        mapping(uint256 => uint256) storage usdtVolume = order.side == OrderUtils.OrderSide.BUY ? buyPriceLevelUsdtVolume : sellPriceLevelUsdtVolume;

        if (priceLevels[price].exists) {
            OrderUtils.PriceLevel storage level = priceLevels[price];
            level.totalVolume -= order.quantityInTokens - order.filled;
            usdtVolume[price] -= order.price * (order.quantityInTokens - order.filled);

            _removeOrderFromPriceLevel(orderId, price, order.side == OrderUtils.OrderSide.BUY);

            if (level.isPriceLevelEmpty()) {
                _removePriceLevel(price, order.side);
                usdtVolume[price] = 0;
            }
        }
    }

    // Remove order from price level array
    function _removeOrderFromPriceLevel(uint256 orderId, uint256 price, bool isBuy) internal {
        mapping(uint256 => uint256[]) storage priceLevelOrders = isBuy ? buyPriceLevelOrders : sellPriceLevelOrders;
        uint256[] storage orderIds = priceLevelOrders[price];

        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == orderId) {
                orderIds[i] = orderIds[orderIds.length - 1];
                orderIds.pop();
                break;
            }
        }

        OrderUtils.Order storage order = orders[orderId];
        OrderUtils.PriceLevel storage level = (isBuy ? buyPriceLevels : sellPriceLevels)[price];

        if (order.prevOrder != 0) {
            orders[order.prevOrder].nextOrder = order.nextOrder;
        } else {
            level.firstOrder = order.nextOrder;
        }

        if (order.nextOrder != 0) {
            orders[order.nextOrder].prevOrder = order.prevOrder;
        } else {
            level.lastOrder = order.prevOrder;
        }

        order.nextOrder = 0;
        order.prevOrder = 0;
    }

    // Remove price level
    function _removePriceLevel(uint256 price, OrderUtils.OrderSide side) internal {
        mapping(uint256 => OrderUtils.PriceLevel) storage priceLevels = side == OrderUtils.OrderSide.BUY ? buyPriceLevels : sellPriceLevels;
        OrderUtils.PriceLevel storage level = priceLevels[price];

        if (side == OrderUtils.OrderSide.BUY) {
            if (bestBidPrice == price) {
                bestBidPrice = level.nextPrice;
            }
        } else {
            if (bestAskPrice == price) {
                bestAskPrice = level.nextPrice;
            }
        }

        if (level.prevPrice != 0) {
            priceLevels[level.prevPrice].nextPrice = level.nextPrice;
        }
        if (level.nextPrice != 0) {
            priceLevels[level.nextPrice].prevPrice = level.prevPrice;
        }

        delete priceLevels[price];
        emit EventUtils.PriceLevelRemoved(price, side);
    }

    // Remove from user open orders
    function _removeFromUserOpenOrders(uint256 orderId) internal {
        OrderUtils.Order storage order = orders[orderId];
        uint256[] storage userOrders = userOpenOrders[order.trader];
        for (uint256 i = 0; i < userOrders.length; i++) {
            if (userOrders[i] == orderId) {
                userOrders[i] = userOrders[userOrders.length - 1];
                userOrders.pop();
                break;
            }
        }
    }

    // Update last traded price
    function _updateLTP(uint256 newPrice) internal {
        lastTradedPrice = newPrice;
        emit EventUtils.LTPUpdated(newPrice, block.timestamp);
    }

    // View functions
    function getOrder(uint256 id) external view returns (OrderUtils.Order memory) {
        return orders[id];
    }

    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOpenOrders[user];
    }

    function getPriceLevel(uint256 price, OrderUtils.OrderSide side) external view returns (OrderUtils.PriceLevel memory) {
        return side == OrderUtils.OrderSide.BUY ? buyPriceLevels[price] : sellPriceLevels[price];
    }

    function getPriceLevelOrders(uint256 price, OrderUtils.OrderSide side) external view returns (uint256[] memory) {
        return side == OrderUtils.OrderSide.BUY ? buyPriceLevelOrders[price] : sellPriceLevelOrders[price];
    }

    function getPriceLevelUsdtVolume(uint256 price, OrderUtils.OrderSide side) external view returns (uint256) {
        return side == OrderUtils.OrderSide.BUY ? buyPriceLevelUsdtVolume[price] : sellPriceLevelUsdtVolume[price];
    }

    function getBestBidAsk() external view returns (uint256 bestBid, uint256 bestAsk) {
        return (bestBidPrice, bestAskPrice);
    }
    

// Function to retrieve price levels for buy or sell side, limited by maxLevels.
// @param side The order side (BUY or SELL) to fetch price levels for.
// @param maxLevels The maximum number of price levels to return, used to:
//   - Control gas costs by limiting storage reads (each level read costs ~200-2100 gas).
//   - Optimize memory usage by pre-allocating arrays of size maxLevels.
//   - Enhance frontend usability by returning only the top N levels (e.g., 10-20 for UI display).
//   - Prevent DoS attacks by capping iteration in deep orderbooks.
//   - Allow flexible data retrieval for callers needing specific depth.
// Note: For all price levels, use off-chain indexing or multiple calls with increasing maxLevels.
    function getPriceLevels(OrderUtils.OrderSide side, uint256 maxLevels) 
        external view 
        returns (uint256[] memory prices, uint256[] memory volumes, uint256[] memory usdtVolumes) {
        prices = new uint256[](maxLevels);
        volumes = new uint256[](maxLevels);
        usdtVolumes = new uint256[](maxLevels);

        uint256 current = side == OrderUtils.OrderSide.BUY ? bestBidPrice : bestAskPrice;
        uint256 count = 0;

        while (current != 0 && count < maxLevels) {
            prices[count] = current;
            volumes[count] = (side == OrderUtils.OrderSide.BUY ? buyPriceLevels : sellPriceLevels)[current].totalVolume;
            usdtVolumes[count] = (side == OrderUtils.OrderSide.BUY ? buyPriceLevelUsdtVolume : sellPriceLevelUsdtVolume)[current];
            current = (side == OrderUtils.OrderSide.BUY ? buyPriceLevels : sellPriceLevels)[current].nextPrice;
            count++;
        }

        assembly {
            mstore(prices, count)
            mstore(volumes, count)
            mstore(usdtVolumes, count)
        }
    }
    

    // Note : Use off-chain indexing to get the all trades info , as in future the trades length will increase and will be 
    // inefficient to get the info from the contract 
    function getTrades() external view returns (OrderUtils.Trade[] memory) {
        return trades;
    }

    function getTradeCount() external view returns (uint256) {
        return trades.length;
    }

    function getSpread() external view returns (uint256) {
        if (bestBidPrice == 0 || bestAskPrice == 0) return 0;
        return bestAskPrice - bestBidPrice;
    }
}