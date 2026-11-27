// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DexPair} from "./DexPair.sol";

/// @title DexFactory
/// @notice Deploys one DexPair per token pair with CREATE2 (salt = sorted tokens), so pair addresses are predictable.
contract DexFactory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 index);

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (t0 == address(0)) revert ZeroAddress();
        if (getPair[t0][t1] != address(0)) revert PairExists();

        pair = address(new DexPair{salt: keccak256(abi.encodePacked(t0, t1))}());
        DexPair(pair).initialize(t0, t1);
        getPair[t0][t1] = pair;
        getPair[t1][t0] = pair;
        allPairs.push(pair);
        emit PairCreated(t0, t1, pair, allPairs.length);
    }
}
