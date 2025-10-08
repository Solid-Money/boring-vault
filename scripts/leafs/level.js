const ethers = require('ethers')

const approve = "0x095ea7b3"
const lvlUSDMint = '0x9136aB0294986267b71BeED86A75eeb3336d09E1'
const boringvault = "0x3e2cD0AeF639CD72Aff864b85acD5c07E2c5e3FA"
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
const lvlUSD = '0x7C1156E515aA1A2E851674120074968C905aAF37'
const sy_lvlUSD = '0x8b9D898327C0Ac74b946Ca3cA9FcfCBE9bc29c48'
const pendleRouter = '0x888888888889758f76e7103c6cbf23abbf58f946'

const LVL_USD_25_SEPT_2025_MAKRET = '0x461bc2ac3f80801BC11B0F20d63B73feF60C8076'

const LevelLeafs = [
    {
        "Description": "Approve lvlusd to mint",
        "LeafDigest": ethers.utils.solidityKeccak256(
            ['address', 'address', 'bool', 'bytes4', 'bytes'],
            [
                '0xd4067b594C6D48990BE42a559C8CfDddad4e8D6F',
                USDC,
                false,
                approve,
                ethers.utils.solidityPack(['address'], [lvlUSDMint]),
            ],
        )
    },
    {
        "AddressArguments": [
            boringvault,
            USDC
        ],
        "CanSendValue": false,
        "DecoderAndSanitizerAddress": "0xd4067b594C6D48990BE42a559C8CfDddad4e8D6F",
        "Description": "Mint lvlUSD with USDC",
        "FunctionSelector": "0xf6d7e1f8",
        "FunctionSignature": "mint((address,address,uint256,uint256))",
        "LeafDigest": ethers.utils.solidityKeccak256(
            ['address', 'address', 'bool', 'bytes4', 'bytes'],
            [
                "0xd4067b594C6D48990BE42a559C8CfDddad4e8D6F",
                lvlUSDMint,
                false,
                '0xf6d7e1f8',
                '0x3e2cD0AeF639CD72Aff864b85acD5c07E2c5e3FAa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48'
            ]
        ),
        "PackedArgumentAddresses": "0x3e2cD0AeF639CD72Aff864b85acD5c07E2c5e3FAa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        "TargetAddress": lvlUSDMint
    },
    {
        "AddressArguments": [pendleRouter],
        "CanSendValue": false,
        "DecoderAndSanitizerAddress": "0xd4067b594C6D48990BE42a559C8CfDddad4e8D6F",
        "Description": "Approve Pendle router to spend lvlUSD",
        "FunctionSelector": approve,
        "FunctionSignature": "approve(address,uint256)",
        "LeafDigest": "0x31053eff4e515c653813e0fdf2258d89ce81eded8b53a011a97c18f2df345470",
        "PackedArgumentAddresses": pendleRouter,
        "TargetAddress": lvlUSD
    },
    {
        "AddressArguments": [
            boringvault,
            sy_lvlUSD,
            lvlUSD,
            lvlUSD,
            "0x0000000000000000000000000000000000000000",
            "0x0000000000000000000000000000000000000000"
        ],
        "CanSendValue": false,
        "DecoderAndSanitizerAddress": "0xd4067b594C6D48990BE42a559C8CfDddad4e8D6F",
        "Description": "Mint SY-lvlUSD using lvlUSD",
        "FunctionSelector": "0x2e071dc6",
        "FunctionSignature": "mintSyFromToken(address,address,uint256,(address,uint256,address,address,(uint8,address,bytes,bool)))",
        "LeafDigest": ethers.utils.solidityKeccak256(
            ['address', 'address', 'bool', 'bytes4', 'bytes'],
            [
                '0xd4067b594C6D48990BE42a559C8CfDddad4e8D6F',
                pendleRouter,
                false,
                '0x2e071dc6',
                ethers.utils.solidityPack(['address', 'address', 'address', 'address', 'address', 'address'], [
                    boringvault,
                    sy_lvlUSD,
                    lvlUSD,
                    lvlUSD,
                    "0x0000000000000000000000000000000000000000",
                    "0x0000000000000000000000000000000000000000"
                ]),
            ],
        ),
        "TargetAddress": pendleRouter
    },
    {
        "AddressArguments": [pendleRouter],
        "CanSendValue": false,
        "DecoderAndSanitizerAddress": "0xd4067b594C6D48990BE42a559C8CfDddad4e8D6F",
        "Description": "Approve Pendle router to spend SY-lvlusd",
        "FunctionSelector": "0x095ea7b3",
        "FunctionSignature": "approve(address,uint256)",
        "LeafDigest": ethers.utils.solidityKeccak256(
            ['address', 'address', 'bool', 'bytes4', 'bytes'],
            [
                '0xd4067b594C6D48990BE42a559C8CfDddad4e8D6F',
                sy_lvlUSD,
                false,
                approve,
                ethers.utils.solidityPack(['address'], [pendleRouter]),
            ],
        ),
        "PackedArgumentAddresses": pendleRouter,
        "TargetAddress": sy_lvlUSD
    },
    {
        "AddressArguments": [
            boringvault,
            LVL_USD_25_SEPT_2025_MAKRET,
        ],
        "CanSendValue": false,
        "DecoderAndSanitizerAddress": "0xdCbC0DeF063C497aA25Eb52eB29aa96C90be0F79",
        "Description": "Swap SY-lvlusd for PT-LVLUSD-25SEP2025",
        "FunctionSelector": "0x2a50917c",
        "FunctionSignature": "swapExactSyForPt(address,address,uint256,uint256,(uint256,uint256,uint256,uint256,uint256),(address,uint256,((uint256,uint256,uint256,uint8,address,address,address,address,uint256,uint256,uint256,bytes),bytes,uint256)[],((uint256,uint256,uint256,uint8,address,address,address,address,uint256,uint256,uint256,bytes),bytes,uint256)[],bytes))",
        "LeafDigest": ethers.utils.solidityKeccak256(
            ['address', 'address', 'bool', 'bytes4', 'bytes'],
            [
                '0xdCbC0DeF063C497aA25Eb52eB29aa96C90be0F79',
                pendleRouter,
                false,
                '0x2a50917c',
                ethers.utils.solidityPack(['address', 'address'], [boringvault, LVL_USD_25_SEPT_2025_MAKRET]),
            ],
        ),
        "TargetAddress": pendleRouter
    },
]

export default LevelLeafs;