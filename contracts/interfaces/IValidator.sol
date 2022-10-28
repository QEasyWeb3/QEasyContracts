//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IValidator {
    function buyStocks(address sender) external payable returns (uint256);
    function sellStocks(address sender, uint256 stocks) external returns (uint256);
    function refund(address payable sender) external;
    function addBonus() external payable;
    function getRate() external view returns (uint256);
    function totalStake() external view returns (uint256);
    function selfStake(address val) external view returns (uint256);
    function validator() external view returns (address);
}