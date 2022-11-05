//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Params.sol";
import "./interfaces/IValidator.sol";
import "./library/SafeSend.sol";

contract Validator is Params, SafeSend, IValidator, Ownable {
    using SafeMath for uint256;

    uint256 public constant InitStockScale = 50;     // Used for initialization of default fund pool
    // self data
    address public gSingerAddress;   // Address of current node
    address public gOwnerAddress;    // Manager address of current node
    uint256 public gSingerRate;        // Commission sharing proportion of current node
    State public gState;         // State of current node
    bool public gAcceptDelegation;
    uint256 public gBlockEpoch;                      // The cycle in which the corresponding update is performed
    // stock pool
    address[] public gAllHolderAddresses;             // all holder address
    mapping(address => bool) public gHolderExist; // holder address exist
    mapping(address => uint256) public gStockMap; // Current verifier's stock record
    uint256 public gTotalStock;                   // Total stocks of current node
    uint256 public gTotalStake;                   // Total stakes of current node

    // Waiting for refund
    struct RefundPendingInfo {
        uint refundPendingWei;
        uint lastRequestBlockNum;
    }
    mapping(address => RefundPendingInfo) public gRefundMap;

    constructor(address singer, address owner, uint256 rate, uint256 stake, bool acceptDelegation, State state, uint256 epoch) {
        gSingerAddress = singer;
        gOwnerAddress = owner;
        gSingerRate = rate;
        gAcceptDelegation = acceptDelegation;
        gState = state;
        uint256 stocks = stakeToStock(stake);
        gStockMap[singer] = stocks;
        gTotalStock = stocks;
        gTotalStake = stake;
        gBlockEpoch = epoch;
    }

    function BuyStocks(address owner) external override payable onlyOwner returns (uint256) {
        if (gHolderExist[owner] == false) {
            gAllHolderAddresses.push(owner);
        }
        uint256 stocks = stakeToStock(msg.value);
        gStockMap[owner] += stocks;
        gTotalStock += stocks;
        gTotalStake += msg.value;
        return stocks;
    }

    function SellStocks(address owner, uint256 stocks) external override onlyOwner returns (uint256) {
        require(gStockMap[owner] >= stocks, "E25");
        uint256 stakes = stockToStake(stocks);
        gStockMap[owner] -= stocks;
        gTotalStock -= stocks;
        gTotalStake -= stakes;
        gRefundMap[owner].refundPendingWei += stakes;
        gRefundMap[owner].lastRequestBlockNum = block.number;
        return stakes;
    }

    function Refund(address payable owner) external override onlyOwner {
        require(block.number >= gRefundMap[owner].lastRequestBlockNum + gBlockEpoch, "E25");
        require(gRefundMap[owner].refundPendingWei > 0, "E26");
        uint256 amount = gRefundMap[owner].refundPendingWei;
        gRefundMap[owner].refundPendingWei = 0;
        gRefundMap[owner].lastRequestBlockNum = block.number;
        sendValue(owner, amount);
    }

    function stakeToStock(uint256 stake) private view returns (uint256) {
        if(gTotalStake == 0) {
            return stake.mul(InitStockScale);
        } 
        return stake.mul(gTotalStock).div(gTotalStake);
    }

    function stockToStake(uint256 stocks) private view returns (uint256) {
        if(gTotalStock == 0) {
            return stocks.div(InitStockScale);
        } 
        return stocks.mul(gTotalStake).div(gTotalStock);
    }

    function AddBonus() external override payable onlyOwner {
        gTotalStake += msg.value;
    }

    function SingerRate() external override view returns (uint256) {
        return gSingerRate;
    }

    function TotalStake() external override view returns (uint256) {
        return gTotalStake;
    }

    function SelfAssets(address owner) external override view returns (uint256) {
        uint256 stocks = gStockMap[owner];
        return stockToStake(stocks);
    }

    function SelfStocks(address owner) external override view returns (uint256) {
        return gStockMap[owner];
    }

    function SingerAddress() external override view returns (address) {
        return gSingerAddress;
    }

    function OwnerAddress() external override view returns (address) {
        return gOwnerAddress;
    }
}
