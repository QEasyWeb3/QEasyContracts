//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IValidator {
    function BuyStocks(address sender) external payable returns (uint256);
    function SellStocks(address sender, uint256 stocks) external returns (uint256);
    function Refund(address payable sender) external;
    function AddBonus() external payable;
    function SingerRate() external view returns (uint256);
    function TotalStake() external view returns (uint256);
    function TotalStock() external view returns (uint256);
    function SelfAssets(address val) external view returns (uint256);
    function SelfStocks(address val) external view returns (uint256);
    function SingerAddress() external view returns (address);
    function OwnerAddress() external view returns (address);
    function SingerState() external view returns (uint8);
    function IsAcceptDelegation() external view returns (bool);
    function IsHolderExist(address holder) external view returns (bool);
    function HolderAddressesLength() external view returns (uint256);
    function HolderAddresses(uint256 startIndex, uint256 count) external view returns (address[] memory);
}
