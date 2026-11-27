// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {DexV3Pool} from "./DexV3Pool.sol";

/// @title DexV3Factory
/// @notice Deploys one DexV3Pool per (token pair, fee tier) with CREATE2. Fee tiers are fixed:
///         0.01% (spacing 1), 0.05% (10), 0.25% (50, the Bushido execution fee), 0.3% (60), 1% (200).
contract DexV3Factory {
    mapping(uint24 => int24) public feeAmountTickSpacing;
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;
    address[] public allPools;

    event PoolCreated(address indexed token0, address indexed token1, uint24 indexed fee, int24 tickSpacing, address pool);

    error IdenticalAddresses();
    error ZeroAddress();
    error FeeNotEnabled();
    error PoolExists();

    constructor() {
        feeAmountTickSpacing[100] = 1;
        feeAmountTickSpacing[500] = 10;
        feeAmountTickSpacing[2500] = 50;
        feeAmountTickSpacing[3000] = 60;
        feeAmountTickSpacing[10000] = 200;
    }

    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (t0 == address(0)) revert ZeroAddress();
        int24 spacing = feeAmountTickSpacing[fee];
        if (spacing == 0) revert FeeNotEnabled();
        if (getPool[t0][t1][fee] != address(0)) revert PoolExists();

        pool = address(new DexV3Pool{salt: keccak256(abi.encode(t0, t1, fee))}(t0, t1, fee, spacing));
        getPool[t0][t1][fee] = pool;
        getPool[t1][t0][fee] = pool;
        allPools.push(pool);
        emit PoolCreated(t0, t1, fee, spacing, pool);
    }
}
