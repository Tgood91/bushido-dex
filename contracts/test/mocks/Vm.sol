// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal Foundry cheatcode interface (no forge-std dependency).
interface Vm {
    function warp(uint256) external;
    function deal(address, uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function assume(bool) external;
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function envAddress(string calldata) external returns (address);
    function envOr(string calldata, uint256) external returns (uint256);
    function envOr(string calldata, string calldata) external returns (string memory);
    function envOr(string calldata, address) external returns (address);
    function createSelectFork(string calldata) external returns (uint256);
    function startBroadcast(address signer) external;
    function stopBroadcast() external;
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
