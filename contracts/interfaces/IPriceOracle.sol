pragma solidity ^0.5.17;

interface IPriceOracle {
    function price(string calldata symbol) external view returns (uint);
}