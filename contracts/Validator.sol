//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Params.sol";
import "./interfaces/IValidator.sol";
import "./library/SafeSend.sol";

uint8 constant StateReady = 1;
uint8 constant StateExit = 2;
uint8 constant StateLazyPunish = 3;
uint8 constant StateDoubleSignPunish = 4;

uint256 constant RateDenominator = 100;// rate denominator

contract Validator is SafeSend, IValidator, Ownable {
    using SafeMath for uint256;

    uint256 public constant InitStockScale = 50;  // Used for initialization of default fund pool
    uint256 public constant SafetyZone = 3;       // Safety zone epoch
    // self data
    address public gSignerAddress;                // Address of current node
    address public gOwnerAddress;                 // Manager address of current node
    uint256 public gSignerRate;                   // Commission sharing proportion of current node
    uint8 public gSignerState;                    // State of current node
    bool public gAcceptDelegation;                // Whether to accept the delegation from other addresses
    uint256 public gBlockEpoch;                   // The cycle in which the corresponding update is performed
    address payable public gCommunityAddress;
    // stock pool
    address[] public gHolderAddresses;            // all holder address
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

    constructor(address signer, address owner, uint256 rate, uint256 stake, bool acceptDelegation, uint8 state, uint256 epoch, address payable communityAddress) {
        gSignerAddress = signer;
        gOwnerAddress = owner;
        gSignerRate = rate;
        gAcceptDelegation = acceptDelegation;
        gSignerState = state;
        uint256 stocks = stakeToStock(stake);
        gStockMap[owner] = stocks;
        gTotalStock = stocks;
        gTotalStake = stake;
        gBlockEpoch = epoch;
        gCommunityAddress = communityAddress;
    }

    function BuyStocks(address owner) external override payable onlyOwner returns (uint256) {
        if (gHolderExist[owner] == false) {
            gHolderAddresses.push(owner);
            gHolderExist[owner] = true;
        }
        uint256 stocks = stakeToStock(msg.value);
        gStockMap[owner] += stocks;
        gTotalStock += stocks;
        gTotalStake += msg.value;
        return stocks;
    }

    function SellStocks(address owner, uint256 stocks) external override onlyOwner returns (uint256) {
        require(gStockMap[owner] >= stocks, "E19");
        uint256 stakes = stockToStake(stocks);
        gStockMap[owner] -= stocks;
        gTotalStock -= stocks;
        gTotalStake -= stakes;
        gRefundMap[owner].refundPendingWei += stakes;
        gRefundMap[owner].lastRequestBlockNum = block.number;
        return stakes;
    }

    function Refund(address payable owner) external override onlyOwner returns (uint256) {
        require(block.number >= gRefundMap[owner].lastRequestBlockNum + gBlockEpoch.mul(SafetyZone), "E20");
        require(gRefundMap[owner].refundPendingWei > 0, "E21");
        uint256 amount = gRefundMap[owner].refundPendingWei;
        gRefundMap[owner].refundPendingWei = 0;
        gRefundMap[owner].lastRequestBlockNum = block.number;
        sendValue(owner, amount);
        return amount;
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

    function SwitchState(uint8 state) external override onlyOwner {
        gSignerState = state;
    }

    function DoPunish(uint256 amercement) external override onlyOwner returns (uint256, uint256) {
        uint256 finalValue = amercement;
        uint256 ownerStocks = gStockMap[gOwnerAddress];
        uint256 ownerStake = stockToStake(ownerStocks);

        uint256 punishInvestor = amercement.mul(gSignerState).div(RateDenominator);
        uint256 ownerPunish = amercement - punishInvestor;
        uint256 ownerArrears = 0;
        uint256 ownerDiffStock = 0;
        uint256 ownerDiffStake = 0;
        if(ownerStake > ownerPunish){
            ownerDiffStake = ownerPunish;
            ownerDiffStock = stakeToStock(ownerPunish);
            gStockMap[gOwnerAddress] -= ownerDiffStock;
        } else {
            ownerDiffStake = ownerStake;
            ownerDiffStock = gStockMap[gOwnerAddress];
            ownerArrears = ownerPunish - ownerStake;
            uint256 amount = gRefundMap[gOwnerAddress].refundPendingWei;
            if(amount >= ownerArrears) {
                gRefundMap[gOwnerAddress].refundPendingWei = amount - ownerArrears;
                ownerArrears = 0;
            } else {
                gRefundMap[gOwnerAddress].refundPendingWei = 0;
                ownerArrears -= amount;
            }
            gStockMap[gOwnerAddress] = 0;
        }
        uint256 totalDiffStake = ownerDiffStake + ownerArrears + punishInvestor;
        if (gTotalStake >= totalDiffStake) {
            gTotalStake -= totalDiffStake;
        } else {
            finalValue = gTotalStake;
            gTotalStake = 0;
        }
        gTotalStock -= ownerDiffStock;
        if (finalValue > 0) {
            sendValue(gCommunityAddress, finalValue);
        }
        return (finalValue, ownerDiffStock);
    }

    function SignerRate() external override view returns (uint256) {
        return gSignerRate;
    }

    function TotalStake() external override view returns (uint256) {
        return gTotalStake;
    }

    function TotalStock() external override view returns (uint256) {
        return gTotalStock;
    }

    function SelfAssets(address holder) external override view returns (uint256) {
        uint256 stocks = gStockMap[holder];
        return stockToStake(stocks);
    }

    function SelfStocks(address holder) external override view returns (uint256) {
        return gStockMap[holder];
    }

    function SignerAddress() external override view returns (address) {
        return gSignerAddress;
    }

    function OwnerAddress() external override view returns (address) {
        return gOwnerAddress;
    }

    function SignerState() external override view returns (uint8) {
        return gSignerState;
    }

    function IsAcceptDelegation() external override view returns (bool) {
        return gAcceptDelegation;
    }

    function IsHolderExist(address holder) external override view returns (bool) {
        return gHolderExist[holder];
    }

    function HolderAddressesLength() external override view returns (uint256) {
        return gHolderAddresses.length;
    }

    function HolderAddresses(uint256 startIndex, uint256 count) external override view returns (address[] memory) {
        uint256 length = gHolderAddresses.length;
        if (length == 0 || startIndex > (length - 1)) {
            return new address[](0);
        }
        uint256 diffCount = length - startIndex;
        if (diffCount < count) {
            count = diffCount;
        }
        address[] memory holderAddresses = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            holderAddresses[i] = gHolderAddresses[startIndex + i];
        }
        return holderAddresses;
    }

    function RefundPendingWei(address owner) external override view returns (uint256) {
        return gRefundMap[owner].refundPendingWei;
    }
}
