// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
    
    mapping(uint256 => OrderUtils.Order) public orders;
    mapping(address => uint256[]) public userOrders;
    mapping(uint256 => OrderUtils.PriceLevel) public priceLevels;
    
    uint256 public bestBidPrice = 0;    // Highest buy price
    uint256 public bestAskPrice = 0;    // Lowest sell price
    
    OrderUtils.Trade[] public trades;

    constructor(bytes32 _marketHash) {
       marketHash = _marketHash ; 
       owner = _msg.sender ;
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
        uint256 _quantity
    ) external returns (uint256) {
        OrderUtils.validateOrderCreation(_orderType, _price, _quantity);
        
        if (_orderType == OrderUtils.OrderType.MARKET) {
            _price = 0; // Market orders don't have a fixed price
        }
        
        uint256 orderId = nextOrderId++;
        
        // Creating a new order struct 
        orders[orderId] = OrderUtils.Order({
            id: orderId,
            trader: msg.sender,
            orderType: _orderType,
            side: _side,
            price: _price,
            quantity: _quantity,
            filled: 0,
            status: OrderUtils.OrderStatus.ACTIVE,
            timestamp: block.timestamp,
            nextOrder: 0,
            prevOrder: 0
        });
        
        // Pushing the order in the userOrder array
        userOrders[msg.sender].push(orderId);
        
        emit EventUtils.OrderCreated(orderId, msg.sender, _orderType, _side, _price, _quantity);
        
        // Try to match the order immediately
        if (_orderType == OrderUtils.OrderType.MARKET) {
            _executeMarketOrder(orderId);
        } else {
            _matchLimitOrder(orderId);
            // Add to orderbook only if not completely filled
            if (orders[orderId].status == OrderUtils.OrderStatus.ACTIVE) {
                _addToOrderbook(orderId);
            }
        }
        return orderId;
    }
    
    // Cancel an order
    function cancelOrder(uint256 orderId) external onlyOrderOwner(orderId) validOrder(orderId) {
        require(orders[orderId].status == OrderUtils.OrderStatus.ACTIVE, "Order not active");
        
        orders[orderId].status = OrderUtils.OrderStatus.CANCELLED;
        _removeFromOrderbook(orderId);
        
        emit EventUtils.OrderCancelled(orderId, msg.sender);
    }
    
    // Execute a market order
    function _executeMarketOrder(uint256 orderId) internal {
        OrderUtils.Order storage order = orders[orderId];
        uint256 remainingQuantity = order.quantity;
        
        if (order.side == OrderUtils.OrderSide.BUY) {
            // Match with sell orders (lowest price first)
            uint256 currentPrice = bestAskPrice;
            while (currentPrice != 0 && remainingQuantity > 0) {
                remainingQuantity = _matchAtPriceLevel(orderId, currentPrice, remainingQuantity, false);
                currentPrice = priceLevels[currentPrice].nextPrice;
            }
        } else {
            // Match with buy orders (highest price first)
            uint256 currentPrice = bestBidPrice;
            while (currentPrice != 0 && remainingQuantity > 0) {
                remainingQuantity = _matchAtPriceLevel(orderId, currentPrice, remainingQuantity, true);
                currentPrice = priceLevels[currentPrice].prevPrice;
            }
        }
        if (remainingQuantity == 0) {
            order.status = OrderUtils.OrderStatus.FILLED;
        }
    }
    
    // Match limit order with existing orders
    function _matchLimitOrder(uint256 orderId) internal {
        OrderUtils.Order storage order = orders[orderId];
        uint256 remainingQuantity = order.quantity;
        
        if (order.side == OrderUtils.OrderSide.BUY) {
            // Match with sell orders at or below buy price
            uint256 currentPrice = bestAskPrice;
            while (currentPrice != 0 && remainingQuantity > 0 && currentPrice <= order.price) {
                remainingQuantity = _matchAtPriceLevel(orderId, currentPrice, remainingQuantity, false);
                currentPrice = priceLevels[currentPrice].nextPrice;
            }
        } else {
            // Match with buy orders at or above sell price
            uint256 currentPrice = bestBidPrice;
            while (currentPrice != 0 && remainingQuantity > 0 && currentPrice >= order.price) {
                remainingQuantity = _matchAtPriceLevel(orderId, currentPrice, remainingQuantity, true);
                currentPrice = priceLevels[currentPrice].prevPrice;
            }
        }
        
        if (orders[orderId].isOrderFullyFilled()) {
            orders[orderId].status = OrderUtils.OrderStatus.FILLED;
        }
    }
    
    // Match orders at a specific price level
    function _matchAtPriceLevel(uint256 incomingOrderId, uint256 price, uint256 maxQuantity, bool matchingWithBuy) internal returns (uint256) {
        if (!priceLevels[price].exists) return maxQuantity;
        
        uint256 currentOrderId = priceLevels[price].firstOrder;
        uint256 remainingQuantity = maxQuantity;
        
        while (currentOrderId != 0 && remainingQuantity > 0) {
            OrderUtils.Order storage currentOrder = orders[currentOrderId];
            uint256 nextOrderId = currentOrder.nextOrder; // Store next before potential removal
            
            if (currentOrder.isOrderActive()) {
                if (matchingWithBuy) {
                    remainingQuantity = _executeTrade(currentOrderId, incomingOrderId, remainingQuantity);
                } else {
                    remainingQuantity = _executeTrade(incomingOrderId, currentOrderId, remainingQuantity);
                }
            }
            currentOrderId = nextOrderId;
        }
        return remainingQuantity;
    }
    
    // Add limit order to orderbook using linked list
    function _addToOrderbook(uint256 orderId) internal {
        OrderUtils.Order storage order = orders[orderId];
        uint256 price = order.price;
        
        // Create price level if it doesn't exist
        if (!priceLevels[price].exists) {
            _createPriceLevel(price, order.side);
        }
        
        // Add order to the end of the price level
        OrderUtils.PriceLevel storage level = priceLevels[price];
        
        if (level.firstOrder == 0) {
            // First order at this price level
            level.firstOrder = orderId;
            level.lastOrder = orderId;
        } else {
            // Add to end of the list
            orders[level.lastOrder].nextOrder = orderId;
            orders[orderId].prevOrder = level.lastOrder;
            level.lastOrder = orderId;
        }
        
        level.totalVolume += order.getRemainingQuantity();
    }
    
    // Create a new price level
    function _createPriceLevel(uint256 price, OrderUtils.OrderSide side) internal {
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
            // New best bid
            if (bestBidPrice != 0) {
                priceLevels[bestBidPrice].prevPrice = price;
                priceLevels[price].nextPrice = bestBidPrice;
            }
            bestBidPrice = price;
        } else {
            // Find correct position
            uint256 current = bestBidPrice;
            while (priceLevels[current].nextPrice != 0 && priceLevels[current].nextPrice > price) {
                current = priceLevels[current].nextPrice;
            }
            
            // Insert after current
            uint256 next = priceLevels[current].nextPrice;
            priceLevels[current].nextPrice = price;
            priceLevels[price].prevPrice = current;
            priceLevels[price].nextPrice = next;
            
            if (next != 0) {
                priceLevels[next].prevPrice = price;
            }
        }
    }
    
    // Insert sell price level (ascending order)
    function _insertSellPriceLevel(uint256 price) internal {
        if (bestAskPrice == 0 || price < bestAskPrice) {
            // New best ask
            if (bestAskPrice != 0) {
                priceLevels[bestAskPrice].prevPrice = price;
                priceLevels[price].nextPrice = bestAskPrice;
            }
            bestAskPrice = price;
        } else {
            // Find correct position
            uint256 current = bestAskPrice;
            while (priceLevels[current].nextPrice != 0 && priceLevels[current].nextPrice < price) {
                current = priceLevels[current].nextPrice;
            }
            
            // Insert after current
            uint256 next = priceLevels[current].nextPrice;
            priceLevels[current].nextPrice = price;
            priceLevels[price].prevPrice = current;
            priceLevels[price].nextPrice = next;
            
            if (next != 0) {
                priceLevels[next].prevPrice = price;
            }
        }
    }
    
    // Remove order from orderbook
    function _removeFromOrderbook(uint256 orderId) internal {
        OrderUtils.Order storage order = orders[orderId];
        uint256 price = order.price;
        
        if (!priceLevels[price].exists) return;
        
        OrderUtils.PriceLevel storage level = priceLevels[price];
        
        // Update volume
        level.totalVolume -= order.getRemainingQuantity();
        
        // Remove from linked list
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
        
        // Clear order's links
        order.nextOrder = 0;
        order.prevOrder = 0;
        
        // Remove price level if empty
        if (level.isPriceLevelEmpty()) {
            _removePriceLevel(price, order.side);
        }
    }
    
    // Remove empty price level
    function _removePriceLevel(uint256 price, OrderUtils.OrderSide side) internal {
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
        
        // Update linked list
        if (level.prevPrice != 0) {
            priceLevels[level.prevPrice].nextPrice = level.nextPrice;
        }
        if (level.nextPrice != 0) {
            priceLevels[level.nextPrice].prevPrice = level.prevPrice;
        }
        
        // Remove price level
        delete priceLevels[price];
        
        emit EventUtils.PriceLevelRemoved(price, side);
    }
    
    // Execute a trade between two orders
    function _executeTrade(uint256 buyOrderId, uint256 sellOrderId, uint256 maxQuantity) internal returns (uint256) {
        OrderUtils.Order storage buyOrder = orders[buyOrderId];
        OrderUtils.Order storage sellOrder = orders[sellOrderId];
        
        uint256 buyRemaining = buyOrder.getRemainingQuantity();
        uint256 sellRemaining = sellOrder.getRemainingQuantity();
        
        uint256 tradeQuantity = OrderUtils.min(OrderUtils.min(buyRemaining, sellRemaining), maxQuantity);
        uint256 tradePrice = sellOrder.price; // Use sell order price for execution
        
        // Update orders
        buyOrder.filled += tradeQuantity;
        sellOrder.filled += tradeQuantity;
        
        // Update price level volumes
        if (priceLevels[buyOrder.price].exists) {
            priceLevels[buyOrder.price].totalVolume -= tradeQuantity;
        }
        if (priceLevels[sellOrder.price].exists) {
            priceLevels[sellOrder.price].totalVolume -= tradeQuantity;
        }
        
        // Mark orders as filled if completely executed
        if (buyOrder.isOrderFullyFilled()) {
            buyOrder.status = OrderUtils.OrderStatus.FILLED;
            _removeFromOrderbook(buyOrderId);
        }
        
        if (sellOrder.isOrderFullyFilled()) {
            sellOrder.status = OrderUtils.OrderStatus.FILLED;
            _removeFromOrderbook(sellOrderId);
        }
        
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
        
        // Update LTP
        _updateLTP(tradePrice);
        
        emit EventUtils.TradeExecuted(nextTradeId - 1, buyOrderId, sellOrderId, buyOrder.trader, sellOrder.trader, tradePrice, tradeQuantity);
        emit EventUtils.OrderFilled(buyOrderId, tradeQuantity, buyOrder.getRemainingQuantity());
        emit EventUtils.OrderFilled(sellOrderId, tradeQuantity, sellOrder.getRemainingQuantity());
        
        return maxQuantity - tradeQuantity;
    }
    
    // Update Last Traded Price
    function _updateLTP(uint256 newPrice) internal {
        lastTradedPrice = newPrice;
        emit EventUtils.LTPUpdated(newPrice, block.timestamp);
    }
    
    // Manually set LTP (for admin purposes)
    function setLTP(uint256 newPrice) external {
        _updateLTP(newPrice);
    }
    
    // View functions
    function getOrder(uint256 orderId) external view returns (OrderUtils.Order memory) {
        return orders[orderId];
    }
    
    function getUserOrders(address user) external view returns (uint256[] memory) {
        return userOrders[user];
    }
    
    function getPriceLevel(uint256 price) external view returns (OrderUtils.PriceLevel memory) {
        return priceLevels[price];
    }
    
    function getBestBidAsk() external view returns (uint256 bestBid, uint256 bestAsk) {
        return (bestBidPrice, bestAskPrice);
    }
    
    function getOrdersAtPrice(uint256 price) external view returns (uint256[] memory orderIds) {
        if (!priceLevels[price].exists) {
            return new uint256[](0);
        }
        
        // Count orders first
        uint256 count = 0;
        uint256 current = priceLevels[price].firstOrder;
        while (current != 0) {
            count++;
            current = orders[current].nextOrder;
        }
        
        // Fill array
        orderIds = new uint256[](count);
        current = priceLevels[price].firstOrder;
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = current;
            current = orders[current].nextOrder;
        }
    }
    
    function getBuyPriceLevels(uint256 maxLevels) external view returns (uint256[] memory prices, uint256[] memory volumes) {
        prices = new uint256[](maxLevels);
        volumes = new uint256[](maxLevels);
        
        uint256 current = bestBidPrice;
        uint256 count = 0;
        
        while (current != 0 && count < maxLevels) {
            prices[count] = current;
            volumes[count] = priceLevels[current].totalVolume;
            current = priceLevels[current].nextPrice;
            count++;
        }
        
        // Resize arrays to actual count
        assembly {
            mstore(prices, count)
            mstore(volumes, count)
        }
    }
    
    function getSellPriceLevels(uint256 maxLevels) external view returns (uint256[] memory prices, uint256[] memory volumes) {
        prices = new uint256[](maxLevels);
        volumes = new uint256[](maxLevels);
        
        uint256 current = bestAskPrice;
        uint256 count = 0;
        
        while (current != 0 && count < maxLevels) {
            prices[count] = current;
            volumes[count] = priceLevels[current].totalVolume;
            current = priceLevels[current].nextPrice;
            count++;
        }
        
        // Resize arrays to actual count
        assembly {
            mstore(prices, count)
            mstore(volumes, count)
        }
    }
    
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