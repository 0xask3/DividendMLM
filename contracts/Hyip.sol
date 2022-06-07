// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./DividendPayingToken.sol";
import "./IterableMapping.sol";

contract Hyip is Ownable {
    using SafeMath for uint256;

    struct Packages {
        uint256 amount;
        uint256 lockPeriod;
        uint256 totalInvestors;
    }

    struct Deposits {
        uint256 depositAmount;
        uint256 depositTime;
    }

    struct Player {
        address referral;
        uint256 referralBonus;
        uint256 dividends;
        uint256 totalInvested;
        uint256 totalWithdrawn;
        uint256 totalReferralBonus;
        uint256 lastClaimTime;
        Deposits[3] deposits;
        mapping(uint8 => uint256) referrals_per_level;
    }

    address payable public marketingWallet;
    address payable public reserveWallet;

    PackageTracker[] public packageTracker;

    uint256 public total_investors;
    uint256 public totalInvested;
    uint256 public totalWithdrawn;
    uint256 public totalReferralBonus;
    uint256 public full_release;

    uint8[] public referralBonuses;

    mapping(address => Player) public players;
    Packages[3] public packages;

    event Deposited(address indexed addr, uint256 amount, uint8 packageId);
    event DividendDistributed(uint8 packageId, uint256 amount);
    event Claim(address indexed addr, uint256 amount);
    event ReferralPayout(address indexed addr, uint256 amount, uint8 level);

    constructor(
        address payable _marketingWallet,
        address payable _reserveWallet
    ) {
        marketingWallet = _marketingWallet;
        reserveWallet = _reserveWallet;

        packageTracker.push(new PackageTracker("Package 1 Tracker", "P1"));
        packageTracker.push(new PackageTracker("Package 2 Tracker", "P2"));
        packageTracker.push(new PackageTracker("Package 3 Tracker", "P3"));

        referralBonuses.push(50);
        referralBonuses.push(15);
        referralBonuses.push(10);
        referralBonuses.push(7);
        referralBonuses.push(6);
        referralBonuses.push(5);
        referralBonuses.push(3);
        referralBonuses.push(3);
        referralBonuses.push(1);

        packages[0].amount = 0.01 ether;
        packages[0].lockPeriod = 1 days;

        packages[1].amount = 0.05 ether;
        packages[1].lockPeriod = 5 days;

        packages[2].amount = 0.1 ether;
        packages[2].lockPeriod = 10 days;

        full_release = 1600990000; //start date
    }

    function deposit(uint8 packageId, address _referral) external payable {
        require(uint256(block.timestamp) > full_release, "Not launched");

        require(msg.sender != _referral, "No self referring");
        require(
            _referral == marketingWallet ||
                players[_referral].totalInvested > 0,
            "Invalid referral"
        );
        require(
            msg.value == packages[packageId].amount,
            "Invalid amount of BNB sent"
        );

        Player storage player = players[msg.sender];

        _setReferral(msg.sender, _referral);

        if (player.totalInvested == 0) {
            total_investors++;
        }

        if (player.deposits[packageId].depositAmount == 0) {
            packages[packageId].totalInvestors++;
        }

        uint256 amount = msg.value;

        player.totalInvested += amount;
        totalInvested += amount;
        player.deposits[packageId].depositAmount += amount.mul(60).div(100); //60% to claim
        player.deposits[packageId].depositTime = block.timestamp;

        _referralPayout(msg.sender, amount / 10); //10% to all referrals
        marketingWallet.transfer(amount.mul(15).div(100)); //15% to marketing wallet
        reserveWallet.transfer(amount.mul(5).div(100)); //5% to reserve wallet

        //10% shared among all holders
        try
            packageTracker[packageId].setBalance(
                payable(msg.sender),
                player.deposits[packageId].depositAmount
            )
        {} catch {}

        (bool success, ) = address(packageTracker[packageId]).call{
            value: amount / 10
        }("");
        if (success) {
            emit DividendDistributed(packageId, amount / 10);
        }

        emit Deposited(msg.sender, msg.value, packageId);
    }

    function setReferral(uint8[] memory newValues) external onlyOwner {
        referralBonuses = new uint8[](newValues.length);
        referralBonuses = newValues;
    }

    function _setReferral(address _addr, address _referral) private {
        if (players[_addr].referral == address(0)) {
            players[_addr].referral = _referral;
            for (uint8 i = 0; i < referralBonuses.length; i++) {
                players[_referral].referrals_per_level[i]++;
                _referral = players[_referral].referral;
                if (_referral == address(0)) break;
            }
        }
    }

    function _referralPayout(address _addr, uint256 _amount) private {
        address ref = players[_addr].referral;

        for (uint8 i = 0; i < referralBonuses.length; i++) {
            if (ref == address(0)) break;
            uint256 bonus = (_amount * referralBonuses[i]) / 1000;

            players[ref].referralBonus += bonus;
            players[ref].totalReferralBonus += bonus;
            totalReferralBonus += bonus;

            emit ReferralPayout(ref, bonus, (i + 1));
            ref = players[ref].referral;
        }
    }

    function claim(uint8 packageId) public {
        require(uint256(block.timestamp) > full_release, "Not launched");
        Player storage player = players[msg.sender];

        _payout(packageId, payable(msg.sender));

        require(
            player.dividends > 0 || player.referralBonus > 0,
            "Zero amount"
        );

        uint256 amount = player.dividends + player.referralBonus;

        if (player.referralBonus > 0) {
            payable(msg.sender).transfer(player.referralBonus);
        }

        player.dividends = 0;
        player.referralBonus = 0;
        player.totalWithdrawn += amount;
        totalWithdrawn += amount;

        emit Claim(msg.sender, amount);
    }

    function withdraw(uint8 packageId) external {
        Player storage player = players[msg.sender];

        require(
            block.timestamp.sub(player.deposits[packageId].depositTime) >=
                packages[packageId].lockPeriod,
            "Cannot withdraw yet"
        );

        payable(msg.sender).transfer(player.deposits[packageId].depositAmount);

        uint256 amount = player.deposits[packageId].depositAmount;

        player.totalWithdrawn += amount;
        totalWithdrawn += amount;

        player.deposits[packageId].depositAmount = 0;
        player.deposits[packageId].depositTime = block.timestamp;
        try
            packageTracker[packageId].setBalance(payable(msg.sender), 0)
        {} catch {}
    }

    function _payout(uint8 _packageId, address payable _addr) private {
        uint256 payout = this.dividendOf(_packageId, _addr);

        if (payout > 0) {
            packageTracker[_packageId].processAccount(_addr);
            players[_addr].lastClaimTime = uint256(block.timestamp);
            players[_addr].dividends += payout;
        }
    }

    function dividendOf(uint8 packageId, address _addr)
        external
        view
        returns (uint256 value)
    {
        (uint256 dividend, uint256 time) = packageTracker[packageId].getAccount(
            _addr
        );
        if (block.timestamp - time >= 6 hours) {
            value = dividend;
        }

        return value;
    }

    function getContractInfo()
        external
        view
        returns (
            uint256 _totalInvested,
            uint256 _total_investors,
            uint256 _totalWithdrawn,
            uint256 _totalReferralBonus,
            uint256 contractBalance
        )
    {
        return (
            totalInvested,
            total_investors,
            totalWithdrawn,
            totalReferralBonus,
            address(this).balance
        );
    }

    function getUserInfo(uint8 _packageId, address _addr)
        external
        view
        returns (
            uint256 for_withdraw,
            uint256 withdrawable_referralBonus,
            uint256 invested,
            uint256 withdrawn,
            uint256 referralBonus,
            uint256[] memory referrals
        )
    {
        Player storage player = players[_addr];
        uint256 payout = this.dividendOf(_packageId, _addr);

        referrals = new uint256[](referralBonuses.length);

        for (uint8 i = 0; i < referralBonuses.length; i++) {
            referrals[i] = player.referrals_per_level[i];
        }

        return (
            payout + player.dividends + player.referralBonus,
            player.referralBonus,
            player.totalInvested,
            player.totalWithdrawn,
            player.totalReferralBonus,
            referrals
        );
    }

    function getUserReferralInfo(address _addr)
        external
        view
        returns (uint256 total, uint256[] memory refPerLevel)
    {
        refPerLevel = new uint256[](referralBonuses.length);
        Player storage player = players[_addr];

        for (uint8 i = 0; i < referralBonuses.length; i++) {
            total += player.referrals_per_level[i];
            refPerLevel[i] = player.referrals_per_level[i];
        }
    }
}

contract PackageTracker is DividendPayingToken, Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private packageHoldersMap;

    mapping(address => uint256) public lastClaimTimes;

    event Claim(address indexed account, uint256 amount);

    constructor(string memory name, string memory ticker)
        DividendPayingToken(name, ticker)
    {}

    function _transfer(
        address,
        address,
        uint256
    ) internal pure override {
        require(false, "Package_Dividend_Tracker: No transfers allowed");
    }

    function withdrawDividend() public pure override {
        require(
            false,
            "Package_Dividend_Tracker: withdrawDividend disabled. Use the 'withdraw' function on the main contract."
        );
    }

    function getNumberOfPackageHolders() external view returns (uint256) {
        return packageHoldersMap.keys.length;
    }

    function getAccount(address account)
        public
        view
        returns (uint256 withdrawableDividends, uint256 lastClaimTime)
    {
        withdrawableDividends = withdrawableDividendOf(account);
        lastClaimTime = lastClaimTimes[account];
    }

    function setBalance(address payable account, uint256 newBalance)
        external
        onlyOwner
    {
        _setBalance(account, newBalance);
        packageHoldersMap.set(account, newBalance);

        if (newBalance == 0) {
            packageHoldersMap.remove(account);
        }
    }

    function processAccount(address payable account)
        public
        onlyOwner
        returns (bool)
    {
        uint256 amount = _withdrawDividendOfUser(account);

        if (amount > 0) {
            lastClaimTimes[account] = block.timestamp;
            emit Claim(account, amount);
            return true;
        }

        return false;
    }
}
