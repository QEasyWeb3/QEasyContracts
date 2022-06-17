//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Params.sol";
import "./interfaces/IValidator.sol";
import "./library/SafeSend.sol";

contract Validator is Params, SafeSend, IValidator, Ownable {
    using SafeMath for uint256;

    uint256 public constant DefaultDefiScale = 50;     // Used for initialization of default fund pool
    // #if !Mainnet
    uint256 public constant RefundPendingTime = 0 days;// Only after waiting interval can the due funds be withdrawn
    // #else
    uint256 public constant RefundPendingTime = 7 days;// Only after waiting interval can the due funds be withdrawn
    // #endif

    // self data
    address public gValidator;   // Address of current node
    address public gClaimer;     // Claimer address of current node
    uint256 public gRate;        // Commission sharing proportion of current node
    State public gState;         // State of current node

    // defi pool
    address[] public gAllHolderAddrs;             // all holder address
    mapping(address => bool) public gHolderExist; // holder address exist
    mapping(address => uint256) public gStockMap; // Current verifier's stock record
    uint256 public gTotalStock;                   // Total stocks of current node
    uint256 public gTotalStake;                   // Total stakes of current node

    // Waiting for refund
    struct RefundPendingInfo {
        uint refundPendingWei;
        uint lastRequestTime;
    }
    mapping(address => RefundPendingInfo) public gRefundMap;

    constructor(address val, address claimer, uint256 rate, uint256 stake, State state) {
        gValidator = val;
        gClaimer = claimer;
        gRate = rate;
        gState = state;
        uint256 stocks = stakeToStock(stake);
        gStockMap[val] = stocks;
        gTotalStock = stocks;
        gTotalStake = stake;
    }

    function buyStocks(address sender) external override payable onlyOwner returns (uint256) {
        address val = getClaimer(sender);
        if (gHolderExist[val] == false) {
            gAllHolderAddrs.push(val);
        }
        uint256 stocks = stakeToStock(msg.value);
        gStockMap[val] += stocks;
        gTotalStock += stocks;
        gTotalStake += msg.value;
        return stocks;
    }

    function sellStocks(address sender, uint256 stocks) external override onlyOwner returns (uint256) {
        address val = getClaimer(sender);
        require(gStockMap[val] >= stocks, "E25");
        uint256 stakes = stockToStake(stocks);
        gStockMap[val] -= stocks;
        gTotalStock -= stocks;
        gTotalStake -= stakes;
        gRefundMap[val].refundPendingWei += stakes;
        gRefundMap[val].lastRequestTime = block.timestamp;
        return stakes;
    }

    function refund(address payable sender) external override onlyOwner{
        address val = getClaimer(sender);
        require(block.timestamp >= gRefundMap[val].lastRequestTime + RefundPendingTime, "E25");
        require(gRefundMap[val].refundPendingWei > 0, "E26");

        uint256 amount = gRefundMap[val].refundPendingWei;
        gRefundMap[val].refundPendingWei = 0;
        gRefundMap[val].lastRequestTime = block.timestamp;

        sendValue(sender, amount);
    }

    function stakeToStock(uint256 stake) private view returns (uint256) {
        if(gTotalStake == 0) {
            return stake.mul(DefaultDefiScale);
        } 
        return stake.mul(gTotalStock).div(gTotalStake);
    }

    function stockToStake(uint256 stocks) private view returns (uint256) {
        if(gTotalStock == 0) {
            return stocks.div(DefaultDefiScale);
        } 
        return stocks.mul(gTotalStake).div(gTotalStock);
    }

    function getClaimer(address sender) private view returns (address) {
        address val;
        if(gClaimer == sender) {
            val = gValidator;
        } else {
            val = sender;
        }
        return val;
    }

    function addBonus() external override payable onlyOwner {
        gTotalStake += msg.value;
    }

    function getRate() external override view returns (uint256) {
        return gRate;
    }

    function totalStake() external override view returns (uint256) {
        return gTotalStake;
    }

    function selfStake() external override view returns (uint256) {
        uint256 stocks = gStockMap[gValidator];
        return stockToStake(stocks);
    }

    function validator() external override view returns (address) {
        return gValidator;
    }
}