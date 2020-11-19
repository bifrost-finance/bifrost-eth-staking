//  =====================================================================================
//
//   ___ __ __    ________  ___   __   _________   ______  ______   ______  ______
//  /__//_//_/\  /_______/\/__/\ /__/\/________/\ /_____/\/_____/\ /_____/\/_____/\
//  \::\| \| \ \ \__.::._\/\::\_\\  \ \__.::.__\/ \:::_ \ \:::_ \ \\:::_ \ \:::_ \ \
//   \:.      \ \   \::\ \  \:. `-\  \ \ \::\ \    \:\ \ \ \:(_) ) )\:\ \ \ \:(_) \ \
//    \:.\-/\  \ \  _\::\ \__\:. _    \ \ \::\ \    \:\ \ \ \: __ `\ \:\ \ \ \: ___\/
//     \. \  \  \ \/__\::\__/\\. \`-\  \ \ \::\ \    \:\/.:| \ \ `\ \ \:\_\ \ \ \ \
//      \__\/ \__\/\________\/ \__\/ \__\/  \__\/     \____/_/\_\/ \_\/\_____\/\_\/
//
//  =====================================================================================

// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./DepositContract.sol";
import "./interfaces/IVETH.sol";

contract MintDrop is Ownable {
    using SafeMath for uint;

    /* ========== CONSTANTS ========== */

    uint constant public BONUS_DURATION = 64 days;
    uint constant public MAX_CLAIM_DURATION = 7 days;
    uint constant public TOTAL_BNC_REWARDS = 120000 ether;

    /* ========== STATE VARIABLES ========== */

    // address of vETH
    address public vETHAddress;
    // address of Ethereum 2.0 Deposit Contract
    address public depositAddress;
    // a flag to control whether the withdraw function is locked
    bool public withdrawLocked;
    // a timestamp when the bonus activity initialized
    uint public bonusStartAt;
    // total amount of ETH deposited to Ethereum 2.0 Deposit Contract
    uint public totalLocked;
    // total amount of ETH deposited in this contract
    uint public totalDeposit;
    // total claimed amount of BNC rewards
    uint public claimedRewards;
    // user address => amount of ETH deposited by this user in this contract
    mapping(address => uint) public myDeposit;
    // user address => amount of BNC rewards that will rewarded to this user
    mapping(address => uint) public myRewards;
    // user address => a timestamp that this user claimed rewards
    mapping(address => uint) public myLastClaimedAt;
    // user address => the address of this user which in ss58 format on Bifrost Network
    mapping(address => string) public bifrostAddress;

    /* ========== EVENTS ========== */

    event Deposit(address indexed sender, uint amount);
    event Withdrawal(address indexed sender, uint amount);
    event Claimed(address indexed sender, uint amount);
    event NewValidator(bytes little_endian_deposit_count);
    event BindAddress(address indexed sender, string bifrostAddress);

    /* ========== CONSTRUCTOR ========== */

    constructor(address vETHAddress_, address depositAddress_, uint bonusStartAt_) public Ownable() {
        vETHAddress = vETHAddress_;
        depositAddress = depositAddress_;
        bonusStartAt = bonusStartAt_;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit() external payable {
        claimRewards();
        myDeposit[msg.sender] = myDeposit[msg.sender].add(msg.value);
        totalDeposit = totalDeposit.add(msg.value);
        IVETH(vETHAddress).mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint amount) external isWithdrawNotLocked {
        claimRewards();
        myDeposit[msg.sender] = myDeposit[msg.sender].sub(amount);
        totalDeposit = totalDeposit.sub(amount);
        IVETH(vETHAddress).burn(msg.sender, amount);
        msg.sender.transfer(amount);
        emit Withdrawal(msg.sender, amount);
    }

    function claimRewards() public {
        // claim must start from bonusStartAt
        if (now < bonusStartAt) {
            if (myLastClaimedAt[msg.sender] == 0) {
                myLastClaimedAt[msg.sender] = bonusStartAt;
            }
            return;
        }
        if (myLastClaimedAt[msg.sender] > 0) {
            uint rewards = getIncrementalRewards(msg.sender);
            myRewards[msg.sender] = myRewards[msg.sender].add(rewards);
            claimedRewards = claimedRewards.add(rewards);
            myLastClaimedAt[msg.sender] = now;
            emit Claimed(msg.sender, myRewards[msg.sender]);
        }
        myLastClaimedAt[msg.sender] = now;
    }

    function lockForValidator(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) external onlyOwner isWithdrawLocked {
        uint amount = 32 ether;
        require(address(this).balance >= amount, "insufficient balance");
        require(address(this).balance.add(totalLocked) == totalDeposit, "invalid balance");
        totalLocked = totalLocked.add(amount);
        IDepositContract(depositAddress).deposit{value: amount}(
            pubkey,
            withdrawal_credentials,
            signature,
            deposit_data_root
        );
        emit NewValidator(IDepositContract(depositAddress).get_deposit_count());
    }

    function bindBifrostAddress(string memory bifrostAddress_) external {
        bifrostAddress[msg.sender] = bifrostAddress_;
        emit BindAddress(msg.sender, bifrostAddress_);
    }

    function lockWithdraw() external onlyOwner {
        withdrawLocked = true;
    }

    function unlockWithdraw() external onlyOwner {
        withdrawLocked = false;
    }

    /* ========== VIEWS ========== */

    function getTotalRewards() public view returns (uint) {
        if (now < bonusStartAt) {
            return 0;
        }
        uint duration = now.sub(bonusStartAt);
        if (duration > BONUS_DURATION) {
            return TOTAL_BNC_REWARDS;
        }
        return TOTAL_BNC_REWARDS.mul(duration).div(BONUS_DURATION);
    }

    function getIncrementalRewards(address target) public view returns (uint) {
        uint totalRewards = getTotalRewards();
        if (
            myLastClaimedAt[target] <= bonusStartAt ||
            totalDeposit == 0 ||
            totalRewards == 0
        ) {
            return 0;
        }
        uint remainingRewards = totalRewards.sub(claimedRewards);
        uint myDuration = now.sub(myLastClaimedAt[target]);
        if (myDuration > MAX_CLAIM_DURATION) {
            myDuration = MAX_CLAIM_DURATION;
        }
        uint rewards = remainingRewards
            .mul(myDeposit[target])
            .div(totalDeposit)
            .mul(myDuration)
            .div(MAX_CLAIM_DURATION);
        return rewards;
    }

    function getRewards(address target) public view returns (uint) {
        return myRewards[target].add(getIncrementalRewards(target));
    }

    modifier isWithdrawLocked() {
        require(withdrawLocked, "withdrawal not locked");
        _;
    }

    modifier isWithdrawNotLocked() {
        require(!withdrawLocked, "withdrawal locked");
        _;
    }
}
