//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IValidator {
    function BuyStocks(address sender) external payable returns (uint256);
    function SellStocks(address sender, uint256 stocks) external returns (uint256);
    function Refund(address payable sender) external returns (uint256);
    function AddBonus() external payable;
    function DoPunish(uint256 amercement) external returns (uint256, uint256);
    function SwitchState(uint8 state) external;
    function SignerRate() external view returns (uint256);
    function TotalStake() external view returns (uint256);
    function TotalStock() external view returns (uint256);
    function SelfAssets(address holder) external view returns (uint256);
    function SelfStocks(address holder) external view returns (uint256);
    function SignerAddress() external view returns (address);
    function OwnerAddress() external view returns (address);
    function SignerState() external view returns (uint8);
    function IsAcceptDelegation() external view returns (bool);
    function IsHolderExist(address holder) external view returns (bool);
    function HolderAddressesLength() external view returns (uint256);
    function HolderAddresses(uint256 startIndex, uint256 count) external view returns (address[] memory);
}
