# Orderbook Smart Contract 

## Overview

The `Orderbook` contract implements a basic on-chain order book for trading, supporting both limit and market orders for buy and sell sides. It manages order matching, price levels, trade execution, and provides various view functions for querying the order book state.
- The contract uses linked lists for efficient order and price level management.
- All state-changing actions emit relevant events for off-chain tracking.


## Key Concepts

- **Order Types:**  
  - `LIMIT`: Orders with a specified price.
  - `MARKET`: Orders executed at the best available price.

- **Order Sides:**  
  - `BUY`: Orders to purchase.
  - `SELL`: Orders to sell.

- **Order Status:**  
  - `ACTIVE`: Order is open and can be matched.
  - `FILLED`: Order has been completely matched.
  - `CANCELLED`: Order has been cancelled by the user.

---

## Data Structures

### Structs

- **Order**
  - `id`: Unique order identifier.
  - `trader`: Address of the order creator.
  - `orderType`: Type of the order (LIMIT or MARKET).
  - `side`: Side of the order (BUY or SELL).
  - `price`: Price in wei (0 for market orders).
  - `quantity`: Total quantity to buy/sell.
  - `filled`: Quantity already filled.
  - `status`: Current status of the order.
  - `timestamp`: Creation time.
  - `nextOrder`, `prevOrder`: Linked list pointers for orders at the same price level.

- **PriceLevel**
  - `price`: Price for this level.
  - `firstOrder`, `lastOrder`: Linked list pointers to orders at this price.
  - `totalVolume`: Total unfilled volume at this price.
  - `nextPrice`, `prevPrice`: Linked list pointers for price levels.
  - `exists`: Whether this price level exists.

- **Trade**
  - `id`: Unique trade identifier.
  - `buyOrderId`, `sellOrderId`: IDs of matched orders.
  - `buyer`, `seller`: Addresses of buyer and seller.
  - `price`: Execution price.
  - `quantity`: Quantity traded.
  - `timestamp`: Execution time.

---

## State Variables

- `nextOrderId`, `nextTradeId`: Counters for unique IDs.
- `lastTradedPrice`: Last traded price (LTP).
- `orders`: Mapping from order ID to `Order`.
- `userOrders`: Mapping from user address to their order IDs.
- `priceLevels`: Mapping from price to `PriceLevel`.
- `bestBidPrice`, `bestAskPrice`: Track the best (highest) bid and best (lowest) ask.
- `trades`: Array of all executed trades.

---

## Events

- `OrderCreated`: Emitted when a new order is created.
- `OrderCancelled`: Emitted when an order is cancelled.
- `OrderFilled`: Emitted when an order is (partially) filled.
- `TradeExecuted`: Emitted when a trade is executed.
- `LTPUpdated`: Emitted when the last traded price is updated.
- `PriceLevelCreated`: Emitted when a new price level is created.
- `PriceLevelRemoved`: Emitted when a price level is removed.

---

## Core Functions

### Order Management

- **createOrder(OrderType, OrderSide, price, quantity)**
  - Creates a new order (limit or market).
  - Emits `OrderCreated`.
  - Tries to match the order immediately.
  - Returns the order ID.

- **cancelOrder(orderId)**
  - Cancels an active order (only by owner).
  - Emits `OrderCancelled`.

### Order Matching (Internal)

- **_executeMarketOrder(orderId)**
  - Matches a market order with the best available prices.

- **_matchLimitOrder(orderId)**
  - Matches a limit order with existing orders at suitable prices.

- **_matchAtPriceLevel(incomingOrderId, price, maxQuantity, matchingWithBuy)**
  - Matches an order at a specific price level.

- **_executeTrade(buyOrderId, sellOrderId, maxQuantity)**
  - Executes a trade between two orders.
  - Updates order status, price levels, and records the trade.
  - Emits `TradeExecuted` and `OrderFilled`.

### Orderbook Management (Internal)

- **_addToOrderbook(orderId)**
  - Adds a limit order to the order book at the correct price level.

- **_removeFromOrderbook(orderId)**
  - Removes an order from the order book and updates price levels if needed.

- **_createPriceLevel(price, side)**
  - Creates a new price level for a given price and side.
  - Emits `PriceLevelCreated`.

- **_removePriceLevel(price, side)**
  - Removes an empty price level.
  - Emits `PriceLevelRemoved`.

- **_insertBuyPriceLevel(price) / _insertSellPriceLevel(price)**
  - Maintains linked list of price levels in sorted order.

### Utility

- **_updateLTP(newPrice)**
  - Updates the last traded price (LTP).
  - Emits `LTPUpdated`.

- **setLTP(newPrice)**
  - Allows manual setting of LTP (for admin/testing).

- **_min(a, b)**
  - Returns the minimum of two values.

---

## View Functions

- **getOrder(orderId)**
  - Returns details of a specific order.

- **getUserOrders(user)**
  - Returns all order IDs for a user.

- **getPriceLevel(price)**
  - Returns details of a specific price level.

- **getBestBidAsk()**
  - Returns the best bid and ask prices.

- **getOrdersAtPrice(price)**
  - Returns all order IDs at a specific price.

- **getBuyPriceLevels(maxLevels) / getSellPriceLevels(maxLevels)**
  - Returns arrays of buy/sell price levels and their volumes, up to `maxLevels`.

- **getTrades()**
  - Returns all executed trades.

- **getTradeCount()**
  - Returns the total number of trades.

- **getSpread()**
  - Returns the spread (difference between best ask and best bid).

---

## Modifiers

- **onlyOrderOwner(orderId)**
  - Restricts function to the owner of the order.

- **validOrder(orderId)**
  - Ensures the order exists.

---

## Usage Example

1. **Create a Limit Order:**
   ```solidity
   createOrder(OrderType.LIMIT, OrderSide.BUY, 1000, 5);
   ```

2. **Create a Market Order:**
   ```solidity
   createOrder(OrderType.MARKET, OrderSide.SELL, 0, 2);
   ```

3. **Cancel an Order:**
   ```solidity
   cancelOrder(orderId);
   ```

4. **Query Best Bid/Ask:**
   ```solidity
   (uint256 bestBid, uint256 bestAsk) = getBestBidAsk();
   ```

---

## Notes

- Orders are matched automatically upon creation if possible.
- The contract uses linked lists for efficient order and price level management.
- All state-changing actions emit relevant events for off-chain tracking.
- The contract does not handle asset transfers; it only manages order and trade logic.

# OrderbookFactory Smart Contract Documentation

## Overview

The `OrderbookFactory` contract is responsible for deploying and managing multiple order book markets. Each market is uniquely identified by a pair of base and quote tokens. The factory ensures that only one order book exists per market and provides functions to create and query order books.

---

## Key Concepts

- **Market:** Defined by a unique pair of base and quote token symbols (as strings).
- **Orderbook:** A deployed instance of the `Orderbook` contract for a specific market.

---

## State Variables

- `marketToOrderbook`: Maps a market hash (base+quote) to the deployed order book address.
- `allOrderbooks`: Array of all deployed order book addresses.

---

## Events

- `OrderbookCreated(bytes32 marketHash, address orderbook, string baseToken, string quoteToken)`: Emitted when a new order book is created for a market.

---

## Core Functions

- **createOrderbook(string baseToken, string quoteToken)**
  - Deploys a new `Orderbook` contract for the given market pair.
  - Ensures only one order book per market.
  - Emits `OrderbookCreated`.
  - Returns the address of the new order book.

- **getOrderbook(string baseToken, string quoteToken)**
  - Returns the address of the order book for the given market pair.

- **getAllOrderbooks()**
  - Returns an array of all deployed order book addresses.

---

## Usage Example

1. **Create a New Orderbook for a Market:**
   ```solidity
   address orderbook = factory.createOrderbook("ETH", "USDC");
   ```

2. **Get an Existing Orderbook Address:**
   ```solidity
   address orderbook = factory.getOrderbook("ETH", "USDC");
   ```

3. **List All Orderbooks:**
   ```solidity
   address[] memory allOrderbooks = factory.getAllOrderbooks();
   ```

---

## Notes

- Each market (base/quote pair) can have only one order book.
- The factory pattern allows easy deployment and management of multiple markets.
- The contract emits events for off-chain tracking of new markets.
