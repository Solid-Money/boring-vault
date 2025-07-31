const { MerkleTree } = require('merkletreejs')
const ethers = require('ethers')
const { keccak256 } = require('ethers/lib/utils')

const swapExactPtForToken = "0x594a88cc"
const swapExactTokenForPt = "0xc81f847a"
const approve = "0x095ea7b3"

const decoderAndSanitizer = "0xf83c975C7bd28B693bb6e091E12C83e04afd4771"
const router = "0x888888888889758F76e7103c6CbF23ABbF58F946"
const boringvault = "0x3e2cD0AeF639CD72Aff864b85acD5c07E2c5e3FA"
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
const pendleSwap = "0xd4F480965D2347d421F1bEC7F545682E5Ec2151D"
const augustusExtRouter = "0x6A000F20005980200259B80c5102003040001068"
const kyberExtRouter = "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5"
const dexRouter = "0x6088d94C5a40CEcd3ae2D4e0710cA687b91c61d0"

const syrupUSDCMarket = "0x9A63FA80b5DDFd3Cab23803fdB93ad2c18F3d5aa"
const syrupUSDC = "0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b"

const lvlUSDMarket = "0x461bc2ac3f80801BC11B0F20d63B73feF60C8076"
const lvlUSD = "0x7C1156E515aA1A2E851674120074968C905aAF37"

const USDC_PT_LVL_USD_25_SEPT_2025 = '0x207f7205fd6c4b602fa792c8b2b60e6006d4a0b8'
const USDC_SYRUP_USD_28_AUG_2025 = '0xcce7d12f683c6dae700154f0badf779c0ba1f89a'

const leaves = [
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            USDC,
            false,
            approve,
            ethers.utils.solidityPack(['address'], [router]),
        ],
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            USDC_PT_LVL_USD_25_SEPT_2025,
            false,
            approve,
            ethers.utils.solidityPack(['address'], [router])
        ]
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            USDC_SYRUP_USD_28_AUG_2025,
            false,
            approve,
            ethers.utils.solidityPack(['address'], [router])
        ]
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            router,
            false,
            swapExactTokenForPt,
            ethers.utils.solidityPack(
                ['address', 'address', 'address', 'address', 'address', 'address'],
                [
                    boringvault,
                    syrupUSDCMarket,
                    USDC,
                    syrupUSDC,
                    pendleSwap,
                    augustusExtRouter,
                ]
            )
        ]
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            router,
            false,
            swapExactPtForToken,
            ethers.utils.solidityPack(
                ['address', 'address', 'address', 'address', 'address', 'address'],
                [
                    boringvault,
                    syrupUSDCMarket,
                    USDC,
                    syrupUSDC,
                    pendleSwap,
                    augustusExtRouter
                ]
            )
        ]
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            router,
            false,
            swapExactTokenForPt,
            ethers.utils.solidityPack(
                ['address', 'address', 'address', 'address', 'address', 'address'],
                [
                    boringvault,
                    lvlUSDMarket,
                    USDC,
                    lvlUSD,
                    pendleSwap,
                    augustusExtRouter
                ]
            )
        ]
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            router,
            false,
            swapExactPtForToken,
            ethers.utils.solidityPack(
                ['address', 'address', 'address', 'address', 'address', 'address'],
                [
                    boringvault,
                    lvlUSDMarket,
                    USDC,
                    lvlUSD,
                    pendleSwap,
                    augustusExtRouter
                ]
            )
        ]
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            router,
            false,
            swapExactTokenForPt,
            ethers.utils.solidityPack(
                ['address', 'address', 'address', 'address', 'address', 'address'],
                [
                    boringvault,
                    syrupUSDCMarket,
                    USDC,
                    syrupUSDC,
                    pendleSwap,
                    kyberExtRouter
                ]
            )
        ]
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            router,
            false,
            swapExactPtForToken,
            ethers.utils.solidityPack(
                ['address', 'address', 'address', 'address', 'address', 'address'],
                [
                    boringvault,
                    syrupUSDCMarket,
                    USDC,
                    syrupUSDC,
                    pendleSwap,
                    kyberExtRouter
                ]
            )
        ]
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            router,
            false,
            swapExactTokenForPt,
            ethers.utils.solidityPack(
                ['address', 'address', 'address', 'address', 'address', 'address'],
                [
                    boringvault,
                    lvlUSDMarket,
                    USDC,
                    lvlUSD,
                    pendleSwap,
                    kyberExtRouter
                ]
            )
        ]
    ),
    ethers.utils.solidityKeccak256(
        ['address', 'address', 'bool', 'bytes4', 'bytes'],
        [
            decoderAndSanitizer,
            router,
            false,
            swapExactPtForToken,
            ethers.utils.solidityPack(
                ['address', 'address', 'address', 'address', 'address', 'address'],
                [
                    boringvault,
                    lvlUSDMarket,
                    USDC,
                    lvlUSD,
                    pendleSwap,
                    kyberExtRouter
                ]
            )
        ]
    ),
]

console.log('leaves', leaves)
const tree = new MerkleTree(leaves, keccak256)
const root = tree.getRoot().toString('hex')
console.log('root', root)
const leaf = ethers.utils.solidityKeccak256(
    ['address', 'address', 'bool', 'bytes4', 'bytes'],
    [
        decoderAndSanitizer,
        router,
        false,
        swapExactPtForToken,
        ethers.utils.solidityPack(
            ['address', 'address', 'address', 'address', 'address', 'address', ],
            [
                boringvault,
                lvlUSDMarket,
                USDC,
                lvlUSD,
                pendleSwap,
                kyberExtRouter,
            ]
        )
    ]
)
const proof = tree.getProof(leaf)
console.log('proof', proof)
console.log(tree.verify(proof, leaf, root)) // true
