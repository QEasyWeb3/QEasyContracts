//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IValidator {
    function BuyStocks(address sender) external payable returns (uint256);
    function SellStocks(address sender, uint256 stocks) external returns (uint256);
    function Refund(address payable sender) external;
    function AddBonus() external payable;
    function SingerRate() external view returns (uint256);
    function TotalStake() external view returns (uint256);
    function SelfAssets(address val) external view returns (uint256);
    function SelfStocks(address val) external view returns (uint256);
    function SingerAddress() external view returns (address);
    function OwnerAddress() external view returns (address);
}
