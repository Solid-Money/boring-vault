const { ethers } = require('hardhat')

// Addresses
const oappAddress = '0x220d4667AA06E0Aa39f62c601690848f2e48BC15'; // Replace with your OApp address
const recLibAddress = '0xB12514e226E50844E4655696c92c0c36B8A53141'; // Replace with your send message library address
const lzEndPointAddress = '0x1a44076050125825900e736c501f859c50fE728c'

// Configuration
// UlnConfig controls verification threshold for incoming messages
// Receive config enforces these settings have been applied to the DVNs and Executor
// 0 values will be interpretted as defaults, so to apply NIL settings, use:
// uint8 internal constant NIL_DVN_COUNT = type(uint8).max;
// uint64 internal constant NIL_CONFIRMATIONS = type(uint64).max;
const remoteEid = 30101; // Example EID, replace with the actual value
const ulnConfig = {
    confirmations: 12, // Example value, replace with actual
    requiredDVNCount: 2, // Example value, replace with actual
    optionalDVNCount: 0, // Example value, replace with actual
    optionalDVNThreshold: 0, // Example value, replace with actual
    // requiredDVNs: ['0x589dedbd617e0cbcb916a9223f4d1300c294236b', '0xa59ba433ac34d2927232918ef5b2eaafcf130ba5'], // ETH
    requiredDVNs: ['0x795f8325af292ff6e58249361d1954893be15aff', '0x809cde2afcf8627312e87a6a7bbffab3f8f347c7'], // FUSE
    optionalDVNs: [], // Replace with actual addresses, must be in alphabetical order
};

async function main() {
    const [deployer] = await ethers.getSigners()
    //get network name
    console.log('Deployer address:', deployer.address)

    // ABI and Contract
    const endpointAbi = [
        'function setConfig(address oappAddress, address sendLibAddress, tuple(uint32 eid, uint32 configType, bytes config)[] setConfigParams) external',
    ];
    const endpointContract = new ethers.Contract(lzEndPointAddress, endpointAbi, deployer);

    // Encode UlnConfig using defaultAbiCoder
    const configTypeUlnStruct =
        'tuple(uint64 confirmations, uint8 requiredDVNCount, uint8 optionalDVNCount, uint8 optionalDVNThreshold, address[] requiredDVNs, address[] optionalDVNs)';
    const encodedUlnConfig = ethers.utils.defaultAbiCoder.encode([configTypeUlnStruct], [ulnConfig]);

    // Define the SetConfigParam structs
    const setConfigParamUln = {
        eid: remoteEid,
        configType: 2, // ULN_CONFIG_TYPE
        config: encodedUlnConfig,
    };

    try {
        const tx = await endpointContract.setConfig(
            oappAddress,
            recLibAddress,
            [setConfigParamUln], // Array of SetConfigParam structs
        );

        console.log('Transaction sent:', tx.hash);
        const receipt = await tx.wait();
        console.log('Transaction confirmed:', receipt.transactionHash);
    } catch (error) {
        console.error('Transaction failed:', error);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
