// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Escrow {
    // The following variables are set up in the contructor.
    address immutable deployerAddress;
    address immutable tokenContract; // The tokens used in the escrow
    address immutable paymentTokenContract; // The tokens used in the payment to the recipient
    uint256 public rewardAmount;
    uint256 public paymentAmount;

    // The following variables are dynamically adjusted by the contract when a bond or cancellation request is submitted.
    address public bondedExecutor;
    uint256 public executionDeadline;
    uint256 public bondAmount;
    uint256 public totalBondsDeposited;
    bool public cancellationRequest;
    bool public started;

    constructor(
        uint _rewardAmount,
        uint _paymentAmount,
        address _tokenContract,
        address _paymentTokenContract
    ) {
        tokenContract = _tokenContract;
        paymentTokenContract = _paymentTokenContract;
        rewardAmount = _rewardAmount;
        paymentAmount = _paymentAmount;
        deployerAddress = msg.sender;
    }

    // takes rewardAmount + paymentAmount from the deployer's balance from the tokenContract.
    function start() public {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        require(!started, "Contract already started");

        IERC20(tokenContract).transferFrom(
            msg.sender,
            address(this),
            rewardAmount + paymentAmount
        );
        started = true;
    }

    // takes _bondAmount from the caller's balance of the tokenContract. The bondstatus is now bonded, execution deadline is current block timestam + 5 minutes. Sets bondedexecutor to the caller. Will only accept a bond if the cancellationrequest is set to false, and no one is bonded.
    function bond(uint256 _bondAmount) public {
        require(started, "Contract not started");
        require(!cancellationRequest, "Cancellation requested");
        require(
            _bondAmount >= rewardAmount / 2,
            "Bond must be at least half of reward amount"
        );

        require(!is_bonded(), "Already bonded");

        // If deadline passed and someone is bonded, add their bond to reward
        if (executionDeadline > 0 && !is_bonded()) {
            rewardAmount += bondAmount;
            totalBondsDeposited += bondAmount;
            resetBondData();
        }

        IERC20(tokenContract).transferFrom(
            msg.sender,
            address(this),
            _bondAmount
        );

        bondedExecutor = msg.sender;
        executionDeadline = block.timestamp + 5 minutes;
        bondAmount = _bondAmount;
    }

    // only deployer can call this. will set the cancellation request to true.
    function requestCancellation() public {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        cancellationRequest = true;
    }

    // sets cancellation request to false, if the caller is deployer
    function resume() public {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        cancellationRequest = false;
    }

    // ignore the proof for now, it's a placeholder, mark it as such. releases the bondAmount + rewardAmount + pyamnetAmount to the caller only and only if the caller is bondedExecutor
    function collect(/*bytes calldata _proof*/) public {
        // TODO: proof verification placeholder
        require(
            msg.sender == bondedExecutor,
            "Only bonded executor can collect"
        );
        require(executionDeadline > 0, "No active bond");
        require(is_bonded(), "Bond expired or not active");

        // Transfer bond amount back to executor
        IERC20(tokenContract).transfer(
            msg.sender,
            bondAmount + rewardAmount + paymentAmount
        );

        resetBondData();
    }

    // checks if contract is currently bonded by verifying deadline
    function is_bonded() public view returns (bool) {
        return executionDeadline > 0 && block.timestamp <= executionDeadline;
    }

    // allows deployer to withdraw all assets except the reward amount
    // only if the contract is not currently bonded (or the execution deadline has passed)
    function withdraw() public {
        require(msg.sender == deployerAddress, "Only callable by the deployer");
        require(!is_bonded(), "Cannot withdraw while bond is active");

        uint256 contractBalance = IERC20(tokenContract).balanceOf(
            address(this)
        );
        uint256 withdrawableAmount = contractBalance - rewardAmount;

        require(withdrawableAmount > 0, "No withdrawable funds");

        IERC20(tokenContract).transfer(msg.sender, withdrawableAmount);

        resetBondData();
    }

    function resetBondData() internal {
        require(!is_bonded(), "Cannot reset while bond is active");

        bondedExecutor = address(0);
        bondAmount = 0;
        executionDeadline = 0;
    }
}
