// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "forge-std/Script.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {FuseRolesAuthority} from "src/fuse/FuseRolesAuthority.sol";
import {BoringVault} from "src/base/BoringVault.sol";
import {AccountantWithRateProviders} from "src/base/Roles/AccountantWithRateProviders.sol";
import {LayerZeroTeller} from "src/base/Roles/CrossChain/Bridges/LayerZero/LayerZeroTeller.sol";
import {ManagerWithMerkleVerification} from "src/base/Roles/ManagerWithMerkleVerification.sol";
import {BoringOnChainQueueWithTracking} from "src/base/Roles/BoringQueue/BoringOnChainQueueWithTracking.sol";
import {BoringSolver} from "src/base/Roles/BoringQueue/BoringSolver.sol";
import {SoBtcConfig, ILayerZeroEndpointSoBtc, ISafeProxyFactory, ISafe} from "./SoBtcConfig.sol";

/**
 * Deploys and configures one chain's soBTC stack, owned by the deployer until HandoverSoBtc.
 * Run once on Ethereum and once on Base; ConnectSoBtc then peers the two tellers.
 *
 *   1. soBTC solver Safe (2-of-5, the soETH solver owners), where the chain has withdrawals
 *   2. RolesAuthority, BoringVault, Accountant (base WBTC, rate 1e8), LayerZeroTeller, Manager, and
 *      where the chain has withdrawals, BoringOnChainQueueWithTracking and BoringSolver
 *   3. Roles as on the soETH authorities: vault manage/enter/exit, rate updater, strategist; public
 *      deposit and bridge; depositAndBridge on Ethereum; queue + solver roles, solver Safe and public
 *      queue request/cancel where the chain has withdrawals
 *   4. Teller as transfer hook; WBTC deposits, and withdraws + queue withdraw asset where the chain
 *      has withdrawals (Ethereum). Base takes deposits only: its WBTC is bridged to Ethereum.
 *   5. DVN/executor config for the pathway to the other chain (the peer is set by ConnectSoBtc)
 *
 *   forge script script/soBTC/DeploySoBtc.s.sol --rpc-url <mainnet|base> --private-key $PRIVATE_KEY --broadcast --slow
 */
contract DeploySoBtc is SoBtcConfig {
    BtcChain internal c;
    address internal solverSafe;
    RolesAuthority internal authority;
    BoringVault internal vault;
    AccountantWithRateProviders internal accountant;
    LayerZeroTeller internal teller;
    ManagerWithMerkleVerification internal manager;
    BoringOnChainQueueWithTracking internal queue;
    BoringSolver internal solver;

    function run() external {
        c = _chain();
        require(!vm.exists(c.record), string.concat(c.record, " exists: soBTC is already deployed there"));
        require(ERC20(c.asset).decimals() == DECIMALS, "Asset is not 8 decimals");

        vm.startBroadcast();
        require(msg.sender == DEPLOYER, "Broadcast from the deployer 0x3B69");
        if (c.withdrawals) _solverSafe();
        _contracts();
        _roles();
        _assets();
        _pathwayConfig();
        vm.stopBroadcast();

        _verify();
        _record();
    }

    function _solverSafe() internal {
        bytes memory init = abi.encodeCall(
            ISafe.setup,
            (_solverSafeOwners(), SOLVER_SAFE_THRESHOLD, address(0), "", SAFE_FALLBACK, address(0), 0, payable(0))
        );
        uint256 salt = uint256(keccak256(bytes(string.concat("solid.soBTC.", c.name, ".solverSafe"))));
        solverSafe = ISafeProxyFactory(SAFE_FACTORY).createProxyWithNonce(SAFE_L2_SINGLETON, init, salt);
    }

    function _contracts() internal {
        authority = new FuseRolesAuthority(DEPLOYER, Authority(address(0)));
        vault = new BoringVault(DEPLOYER, NAME, SYMBOL, DECIMALS);
        accountant = new AccountantWithRateProviders(
            DEPLOYER,
            address(vault),
            PAYOUT,
            START_RATE,
            c.asset,
            RATE_CHANGE_UPPER,
            RATE_CHANGE_LOWER,
            MIN_UPDATE_DELAY,
            PLATFORM_FEE,
            PERFORMANCE_FEE
        );
        // The deployer is the LayerZero delegate until the handover, so it can set the pathway config.
        teller = new LayerZeroTeller(
            DEPLOYER, address(vault), address(accountant), c.weth, LZ_ENDPOINT, DEPLOYER, address(0)
        );
        manager = new ManagerWithMerkleVerification(DEPLOYER, address(vault), BALANCER_VAULT);
        if (c.withdrawals) {
            queue = new BoringOnChainQueueWithTracking(
                DEPLOYER, address(authority), payable(address(vault)), address(accountant), TRACK_WITHDRAWS_ON_CHAIN
            );
            solver =
                new BoringSolver(DEPLOYER, address(authority), address(queue), EXCESS_TO_SOLVER_NON_SELF_SOLVE);
        }

        vault.setAuthority(authority);
        accountant.setAuthority(authority);
        teller.setAuthority(authority);
        manager.setAuthority(authority);
    }

    function _roles() internal {
        RolesAuthority a = authority;
        a.setRoleCapability(MANAGER_ROLE, address(vault), VAULT_MANAGE, true);
        a.setRoleCapability(MINTER_ROLE, address(vault), VAULT_ENTER, true);
        a.setRoleCapability(BURNER_ROLE, address(vault), VAULT_EXIT, true);
        a.setRoleCapability(UPDATE_EXCHANGE_RATE_ROLE, address(accountant), ACCOUNTANT_UPDATE_RATE, true);
        a.setRoleCapability(STRATEGIST_ROLE, address(manager), MANAGER_MANAGE_MERKLE, true);

        a.setUserRole(address(manager), MANAGER_ROLE, true);
        a.setUserRole(address(teller), MINTER_ROLE, true);
        a.setUserRole(address(teller), BURNER_ROLE, true);
        a.setUserRole(RATE_UPDATER, UPDATE_EXCHANGE_RATE_ROLE, true);
        a.setUserRole(STRATEGIST, STRATEGIST_ROLE, true);

        a.setPublicCapability(address(teller), TELLER_DEPOSIT, true);
        a.setPublicCapability(address(teller), TELLER_BRIDGE, true);
        if (c.depositAndBridge) a.setPublicCapability(address(teller), TELLER_DEPOSIT_AND_BRIDGE, true);

        if (!c.withdrawals) return;
        a.setRoleCapability(SOLVER_ROLE, address(queue), QUEUE_SOLVE, true);
        a.setRoleCapability(BULK_WITHDRAW_ROLE, address(teller), TELLER_BULK_WITHDRAW, true);
        a.setRoleCapability(CAN_SOLVE_ROLE, address(solver), SOLVER_REDEEM_SOLVE, true);
        a.setRoleCapability(ONLY_QUEUE_ROLE, address(solver), SOLVER_BORING_SOLVE, true);
        a.setRoleCapability(SOLVER_ORIGIN_ROLE, address(queue), QUEUE_CANCEL_USER_WITHDRAWS, true);
        a.setUserRole(address(solver), SOLVER_ROLE, true);
        a.setUserRole(address(solver), BULK_WITHDRAW_ROLE, true);
        a.setUserRole(address(queue), ONLY_QUEUE_ROLE, true);
        a.setUserRole(solverSafe, CAN_SOLVE_ROLE, true);
        a.setUserRole(solverSafe, SOLVER_ORIGIN_ROLE, true);
        a.setPublicCapability(address(queue), QUEUE_REQUEST, true);
        a.setPublicCapability(address(queue), QUEUE_CANCEL_BY_ID, true);
    }

    function _assets() internal {
        // Share lock and deny lists, as on soETH.
        vault.setBeforeTransferHook(address(teller));
        // Base: deposits only. Its WBTC is bridged to Ethereum, which pays every withdrawal.
        teller.updateAssetData(ERC20(c.asset), true, c.withdrawals, 0);
        if (!c.withdrawals) return;
        queue.updateWithdrawAsset(
            c.asset, SECONDS_TO_MATURITY, MINIMUM_SECONDS_TO_DEADLINE, MIN_DISCOUNT, MAX_DISCOUNT, MINIMUM_SHARES
        );
    }

    // Config before the peer exists, so no message ever runs on LayerZero's defaults.
    function _pathwayConfig() internal {
        ILayerZeroEndpointSoBtc endpoint = ILayerZeroEndpointSoBtc(LZ_ENDPOINT);
        require(endpoint.getSendLibrary(address(teller), c.peerEid) == c.sendLib, "Unexpected send library");
        (address lib,) = endpoint.getReceiveLibrary(address(teller), c.peerEid);
        require(lib == c.receiveLib, "Unexpected receive library");

        SetConfigParam[] memory send = new SetConfigParam[](2);
        send[0] = _uln(c.peerEid, c.confSend, c.dvnLow, c.dvnHigh);
        send[1] = _executor(c.peerEid, c.executor);
        endpoint.setConfig(address(teller), c.sendLib, send);

        SetConfigParam[] memory receive_ = new SetConfigParam[](1);
        receive_[0] = _uln(c.peerEid, c.confReceive, c.dvnLow, c.dvnHigh);
        endpoint.setConfig(address(teller), c.receiveLib, receive_);
    }

    function _verify() internal view {
        require(accountant.getRate() == START_RATE, "Start rate");
        require(address(accountant.base()) == c.asset, "Accountant base");
        require(vault.decimals() == DECIMALS, "Vault decimals");
        require(address(vault.hook()) == address(teller), "Hook");
        (bool allowDeposits, bool allowWithdraws,) = teller.assetData(ERC20(c.asset));
        require(allowDeposits && allowWithdraws == c.withdrawals, "Teller asset data");
        require(authority.canCall(STRATEGIST, address(manager), MANAGER_MANAGE_MERKLE), "Strategist manage");
        if (c.withdrawals) {
            ISafe s = ISafe(solverSafe);
            require(s.getThreshold() == SOLVER_SAFE_THRESHOLD && s.getOwners().length == 5, "Solver Safe setup");
            require(authority.canCall(address(solver), address(teller), TELLER_BULK_WITHDRAW), "Solver bulkWithdraw");
            require(authority.canCall(solverSafe, address(solver), SOLVER_REDEEM_SOLVE), "Solver Safe solve");
            require(authority.canCall(address(0xbeef), address(queue), QUEUE_REQUEST), "Public request");
        } else {
            require(address(queue) == address(0) && solverSafe == address(0), "No queue without withdrawals");
        }
        require(
            authority.canCall(address(0xbeef), address(teller), TELLER_DEPOSIT_AND_BRIDGE) == c.depositAndBridge,
            "depositAndBridge"
        );
        require(!authority.canCall(DEPLOYER, address(vault), VAULT_ENTER), "Deployer can mint");
        // The backend and UI ship the vault address before the deploy (CREATE from the deployer's
        // nonce). A deployer nonce that moved would put it elsewhere: stop in the simulation.
        address expected = vm.envOr("SOBTC_EXPECT_VAULT", address(0));
        require(expected == address(0) || address(vault) == expected, "Vault address differs from SOBTC_EXPECT_VAULT");
    }

    function _record() internal {
        string memory j = "soBTC";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeUint(j, "startingExchangeRate", START_RATE);
        vm.serializeAddress(j, "asset", c.asset);
        vm.serializeAddress(j, "RolesAuthority", address(authority));
        vm.serializeAddress(j, "BoringVault", address(vault));
        vm.serializeAddress(j, "Accountant", address(accountant));
        vm.serializeAddress(j, "LayerZeroTeller", address(teller));
        string memory out = vm.serializeAddress(j, "Manager", address(manager));
        if (c.withdrawals) {
            vm.serializeAddress(j, "BoringQueue", address(queue));
            vm.serializeAddress(j, "BoringSolver", address(solver));
            out = vm.serializeAddress(j, "SolverSafe", solverSafe);
        }
        vm.writeJson(out, c.record);

        console.log(string.concat("soBTC on ", c.name));
        console.log("SolverSafe     ", solverSafe);
        console.log("RolesAuthority ", address(authority));
        console.log("BoringVault    ", address(vault));
        console.log("Accountant     ", address(accountant));
        console.log("LayerZeroTeller", address(teller));
        console.log("Manager        ", address(manager));
        if (!c.withdrawals) return;
        console.log("BoringQueue    ", address(queue));
        console.log("BoringSolver   ", address(solver));
    }
}
