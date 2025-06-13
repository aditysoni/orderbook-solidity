// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Orderbook.sol";

contract OrderbookFactory {

    mapping(bytes32 => address) public marketToOrderbook ;
    address[] public allOrderbooks;

    event OrderbookCreated(bytes32 indexed marketHash, address orderbook, address baseToken, address quoteToken);

    function createOrderbook(address baseToken, address quoteToken) external returns (address) {
        bytes32 marketHash = keccak256(abi.encodePacked(baseToken, quoteToken));
        require(marketToOrderbook[marketHash] == address(0), "Orderbook already exists");

        Orderbook orderbook = new Orderbook(marketHash, quoteToken, baseToken);
        marketToOrderbook[marketHash] = address(orderbook);
        allOrderbooks.push(address(orderbook));

        emit OrderbookCreated(marketHash, address(orderbook), baseToken, quoteToken);

        return address(orderbook);
    }

    function getOrderbook(string memory baseToken, string memory quoteToken) external view returns (address) {
        return marketToOrderbook[keccak256(abi.encodePacked(baseToken, quoteToken))];
    }

    function getAllOrderbooks() external view returns (address[] memory) {
        return allOrderbooks;
    }
}
