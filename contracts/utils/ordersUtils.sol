// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


library OrderUtils {
    // Enums
    enum OrderType { LIMIT, MARKET }
    enum OrderSide { BUY, SELL }
    enum OrderStatus { ACTIVE, FILLED, CANCELLED }
    
    // Structs
    struct Order {
        uint256 id;
        address trader;
        OrderType orderType;
        OrderSide side;
        uint256 price;      // Price in wei (0 for market orders)
        uint256 quantity;   // Quantity to buy/sell
        uint256 filled;     // Amount already filled
        OrderStatus status;
        uint256 timestamp;
        uint256 nextOrder;  // Next order in the same price level
        uint256 prevOrder;  // Previous order in the same price level
    }
    
    struct PriceLevel {
        uint256 price;
        uint256 firstOrder;    // First order at this price level
        uint256 lastOrder;     // Last order at this price level
        uint256 totalVolume;   // Total volume at this price level
        uint256 nextPrice;     // Next price level (higher for buy, lower for sell)
        uint256 prevPrice;     // Previous price level
        bool exists;           // Whether this price level exists
    }
    
    struct Trade {
        uint256 id;
        uint256 buyOrderId;
        uint256 sellOrderId;
        address buyer;
        address seller;
        uint256 price;
        uint256 quantity;
        uint256 timestamp;
    }
    
    // Utility functions
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    // Order validation functions
    function validateOrderCreation(
        OrderType _orderType,
        uint256 _price,
        uint256 _quantity
    ) internal pure {
        require(_quantity > 0, "Quantity must be greater than 0");
        
        if (_orderType == OrderType.LIMIT) {
            require(_price > 0, "Limit order must have price > 0");
        }
    }
    
    function isOrderActive(Order storage order) internal view returns (bool) {
        return order.status == OrderStatus.ACTIVE;
    }
    
    function getRemainingQuantity(Order storage order) internal view returns (uint256) {
        return order.quantity - order.filled;
    }
    
    function isOrderFullyFilled(Order storage order) internal view returns (bool) {
        return order.filled == order.quantity;
    }
    
    // Price level utility functions
    function isPriceLevelEmpty(PriceLevel storage level) internal view returns (bool) {
        return level.firstOrder == 0;
    }
    
    function canMatchOrders(
        Order storage incomingOrder,
        Order storage existingOrder
    ) internal view returns (bool) {
        if (incomingOrder.side == existingOrder.side) {
            return false; // Same side orders can't match
        }
        
        if (incomingOrder.side == OrderSide.BUY) {
            // Buy order can match if its price >= sell order price
            return incomingOrder.orderType == OrderType.MARKET || 
                   incomingOrder.price >= existingOrder.price;
        } else {
            // Sell order can match if its price <= buy order price
            return incomingOrder.orderType == OrderType.MARKET || 
                   incomingOrder.price <= existingOrder.price;
        }
    }
}