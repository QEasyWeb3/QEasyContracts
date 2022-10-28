//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./library/Initializable.sol";
import "./Params.sol";
import "./Validator.sol";
import "./interfaces/IValidator.sol";
import "./library/SortedList.sol";

contract SystemContract is Initializable, Params, SafeSend {
    using SafeMath for uint256;
    using Address for address;
    using SortedLinkedList for SortedLinkedList.List;

    uint256 public constant RateDenominator = 100;   // rate denominator
    uint256 public gBlockEpoch;                      // The cycle in which the corresponding update is performed
    uint256 public gMinSelfStake;                    // Become the verifier's own minimum stake
    address payable public gCommunityAddress;        //
    address public gAdminAddress;
    uint8 public gMaxValidators;                     // Maximum number of activation verifiers supported
    uint8 public gShareOutBonusPercent;              //

    uint256 public gTotalStake;                      // Total stake amount of the whole network
    uint256 public gTotalPendingShare;               // Total amount to be share
    address[] public gActiveValidators;              // Validator address of the outgoing block in the current epoch
    mapping(address => IValidator) public gValidatorsMap;  // mapping from validator address to validator contract.
    SortedLinkedList.List topValidators;             // A sorted linked list of all valid validators

    enum Operation {ShareOutBonus, UpdateValidators, LazyPunish, DecreaseMissingBlockCounter}
    mapping(uint256 => mapping(Operation => bool)) operationsDone;
    mapping(bytes32 => bool) public doubleSignPunished;

    modifier onlyLocal() {
        require(msg.sender == address(0x0000000000000000000000000000000000000000), "E00");
        _;
    }

    modifier onlyGenesisBlock() {
        require(block.number == 0, "E01");
        _;
    }

    modifier onlyNotExistValidator(address val) {
        require(gValidatorsMap[val] == IValidator(address(0)), "E02");
        _;
    }

    modifier onlyExistValidator(address val) {
        require(gValidatorsMap[val] != IValidator(address(0)), "E03");
        _;
    }

    modifier onlyNotContract(address val) {
        require(!val.isContract(), "E02");
        _;
    }

    modifier onlyMiner() {
        require(msg.sender == block.coinbase, "E04");
        _;
    }

    modifier onlyValidAddress(address addr) {
        require(addr != address(0), "E05");
        _;
    }
    
    modifier onlyValid100(uint256 rate) {
        require(rate <= RateDenominator, "E06");
        _;
    }

    modifier onlyGreaterZero(uint256 amount) {
        require(amount > 0, "E07");
        _;
    }

    modifier onlyOperateOnce(Operation operation) {
        require(!operationsDone[block.number][operation], "E06");
        operationsDone[block.number][operation] = true;
        _;
    }

    modifier onlyBlockEpoch() {
        require(block.number % gBlockEpoch == 0, "E17");
        _;
    }

    modifier onlyNotDoubleSignPunished(bytes32 punishHash) {
        require(!doubleSignPunished[punishHash], "E06");
        _;
    }

    function initialize(address adminAddress, uint8 maxValidators, uint256 epoch, uint256 minSelfStake,
        address payable communityAddress, uint8 shareOutBonusPercent)
        external
        onlyValid100(maxValidators)
        onlyGreaterZero(maxValidators)
        onlyGreaterZero(epoch)
        onlyValidAddress(communityAddress)
        onlyValid100(shareOutBonusPercent)
        initializer {

        gAdminAddress = adminAddress;
        gMaxValidators = maxValidators;
        gBlockEpoch = epoch;
        gMinSelfStake = minSelfStake;
        gCommunityAddress = communityAddress;
        gShareOutBonusPercent = shareOutBonusPercent;
    }

    function initValidator(address val, address manager, uint256 rate, uint256 stake, bool acceptDelegation)
        external
        onlyNotExistValidator(val)
        onlyValidAddress(val)
        onlyValidAddress(manager)
        onlyValid100(rate)
        onlyGreaterZero(stake)
        // #if Mainnet
        onlyGenesisBlock
        // #endif
        onlyInitialized {

        IValidator iVal = new Validator(val, manager, rate, stake, acceptDelegation, State.Ready);
        gValidatorsMap[val] = iVal;
        topValidators.improveRanking(iVal);

        gTotalStake = gTotalStake.add(stake);
    }

    function registerValidator(address val, address manager, uint256 rate, bool acceptDelegation)
        external
        payable
        onlyNotExistValidator(val)
        onlyValidAddress(val)
        onlyValidAddress(manager)
        onlyNotContract(val)
        onlyNotContract(manager)
        onlyValid100(rate)
        onlyInitialized {

        require(msg.value >= gMinSelfStake, "E20");
        IValidator iVal = new Validator(val, manager, rate, msg.value, acceptDelegation, State.Ready);
        gValidatorsMap[val] = iVal;
        topValidators.improveRanking(iVal);

        gTotalStake = gTotalStake.add(msg.value);
    }

    function buyStocks(address val)
        external
        payable
        onlyGreaterZero(msg.value)
        onlyExistValidator(val)
        onlyNotContract(msg.sender) {

        IValidator iVal = gValidatorsMap[val];
        iVal.buyStocks{value : msg.value}(msg.sender);

        if(iVal.selfStake(val) >= gMinSelfStake) {
            topValidators.improveRanking(iVal);
        }

        gTotalStake = gTotalStake.add(msg.value);
    }

    function sellStocks(address val, uint256 stocks)
        external
        onlyGreaterZero(stocks)
        onlyExistValidator(val)
        onlyNotContract(msg.sender) {

        IValidator iVal = gValidatorsMap[val];
        uint256 stakes = iVal.sellStocks(msg.sender, stocks);
        if(iVal.selfStake(val) < gMinSelfStake) {
            topValidators.removeRanking(iVal);
        } else {
            topValidators.lowerRanking(iVal);
        }
        gTotalStake = gTotalStake.sub(stakes);
    }

    function refund(address val)
        external
        onlyExistValidator(val) {

        address payable sender = payable(msg.sender);
        IValidator iVal = gValidatorsMap[val];
        iVal.refund(sender);
    }

    function distributeBlockFee()
        external
        payable
        // #if !Mainnet
        onlyLocal
        // #endif
        onlyOperateOnce(Operation.ShareOutBonus) {

        if (msg.value > 0) {
            gTotalPendingShare += msg.value;
        }
    }

    function shareOutBonusAtBlockEpoch() private {
        uint cnt = gActiveValidators.length;
        if (gTotalPendingShare > 0 && cnt > 0) {
            uint256 amount = gTotalPendingShare;
            gTotalPendingShare = 0;
            uint bonusSingle = amount.mul(gShareOutBonusPercent).div(RateDenominator).div(cnt);
            uint cpFee = amount - (bonusSingle * cnt);
            for (uint i = 0; i < cnt; i++) {
                address val = gActiveValidators[i];
                IValidator iVal = gValidatorsMap[val];
                uint256 rate = iVal.getRate();
                uint256 bonusInvestor = bonusSingle.mul(rate).div(RateDenominator);
                uint256 bonusValidator = bonusSingle - bonusInvestor;
                if(bonusInvestor > 0) {
                    iVal.addBonus{value : bonusInvestor}();
                }
                if(bonusValidator > 0) {
                    iVal.buyStocks{value : bonusValidator}(val);
                }
            }
            if(cpFee > 0) {
                sendValue(gCommunityAddress, cpFee);
            }
        }
    }

    function getTopValidators(uint8 _count) external view returns (address[] memory) {
        // Use default MaxValidators if _count is not provided.
        if (_count == 0) {
            _count = gMaxValidators;
        }
        // set max limit: min(_count, list.length)
        if (_count > topValidators.length) {
            _count = topValidators.length;
        }

        address[] memory _topValidators = new address[](_count);
        IValidator cur = topValidators.head;
        for (uint8 i = 0; i < _count; i++) {
            _topValidators[i] = cur.validator();
            cur = topValidators.next[cur];
        }
        return _topValidators;
    }

    function updateActiveValidatorSet(address[] memory newSet)
    external
        // #if Mainnet
    onlyLocal
        // #endif
    onlyOperateOnce(Operation.UpdateValidators)
    onlyBlockEpoch
    {
        // empty validators set
        require(newSet.length > 0, "E18");
        gActiveValidators = newSet;

        shareOutBonusAtBlockEpoch();
    }

    function getActiveValidators() external view returns (address[] memory){
        return gActiveValidators;
    }

    function lazyPunish(address _val)
        external
            // #if Mainnet
        onlyLocal
            // #endif
        onlyExistValidator(_val)
        onlyOperateOnce(Operation.LazyPunish){
        // TODO
    }

    function decreaseMissedBlocksCounter()
        external
            // #if Mainnet
        onlyLocal
            // #endif
        onlyBlockEpoch
        onlyOperateOnce(Operation.DecreaseMissingBlockCounter){
        // TODO
    }

    function doubleSignPunish(bytes32 _punishHash, address _val)
    external
        // #if Mainnet
    onlyLocal
        // #endif
    onlyExistValidator(_val)
    onlyNotDoubleSignPunished(_punishHash)
    {
        doubleSignPunished[_punishHash] = true;
        // TODO
    }

    function isDoubleSignPunished(bytes32 punishHash) public view returns (bool) {
        return doubleSignPunished[punishHash];
    }

    function totalAssets(address val, address investor) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[val];
        return iVal.selfStake(investor);
    }

    function totalStocks(address val, address investor) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[val];
        return iVal.selfStocks(investor);
    }
}