// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ordersUtils.sol";

library EventUtils {

    using OrderUtils for OrderUtils.OrderType;
    using OrderUtils for OrderUtils.OrderSide ;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        OrderUtils.OrderType orderType,
        OrderUtils.OrderSide side,
        uint256 price,
        uint256 quantity
    );

    event OrderCancelled(
        uint256 indexed orderId,
        address indexed trader
    );

    event OrderFilled(
        uint256 indexed orderId,
        uint256 filledQuantity,
        uint256 remainingQuantity
    );

    event TradeExecuted(
        uint256 indexed tradeId,
        uint256 buyOrderId,
        uint256 sellOrderId,
        address buyer,
        address seller,
        uint256 price,
        uint256 quantity
    );

    event LTPUpdated(
        uint256 newPrice,
        uint256 timestamp
    );

    event PriceLevelCreated(
        uint256 price,
       OrderUtils.OrderSide side
    );

    event PriceLevelRemoved(
        uint256 price,
        OrderUtils.OrderSide side
    );
}
