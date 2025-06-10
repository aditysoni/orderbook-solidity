///SPDX License : MIT 

pragma solidity ^0.8.20;

library Orders {
   
   enum OrderType {
       Market, Limit 
   }

   struct Order {
        uint256 id;
        address trader;
        OrderType orderType;
        uint256 price;
        uint256 size;
        uint256 timestamp;
        uint256 nextOrderId;
        uint256 prevOrderId;
        bool side ; 
    }

    function createOrder () {

    }

    function _createOrder() {

    }

    function executeOrder() {

    }

    function _executeOrder() {

    }

    function _cancelOrder () {

    }

    function pauseOrderBook() {

    }

    function unPauseOrderBook() {

    }

    function getOrdersByAccount() {

    }

    function getOrdersByPrice() {

    }
    
    //getting the orderList of one side 
    function getOrderList(bool side) {

    }

    function matchOrders() {

    }
}