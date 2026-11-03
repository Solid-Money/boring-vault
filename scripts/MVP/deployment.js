const fs = require('fs')
const path = require('path')

// Each vault's settings and deployed addresses live in one record file per environment. Every MVP
// script reads the record named by VAULT_SYMBOL (soEUR when unset) and DEPLOYMENT (qa or prod):
// PROD is deployments/addresses/Base/<VAULT_SYMBOL>.json and QA is <VAULT_SYMBOL>-qa.json, so a run
// can only ever touch that one vault in that one environment.
// DEPLOYMENT_FILE points at any other record instead (the fork dry run uses a scratch copy).
function recordPath() {
  if (process.env.DEPLOYMENT_FILE) return path.resolve(process.env.DEPLOYMENT_FILE)
  const env = process.env.DEPLOYMENT
  if (env !== 'qa' && env !== 'prod') throw new Error('Set DEPLOYMENT=qa or DEPLOYMENT=prod')
  const vault = process.env.VAULT_SYMBOL || 'soEUR'
  if (!/^so[A-Z]+$/.test(vault)) throw new Error(`VAULT_SYMBOL must be a vault symbol such as soEUR or soNVDA, not ${vault}`)
  const file = path.join(__dirname, '..', '..', 'deployments', 'addresses', 'Base', `${vault}${env === 'qa' ? '-qa' : ''}.json`)
  if (!fs.existsSync(file)) throw new Error(`${vault} has no ${env} record at ${file}`)
  return file
}

function load() {
  const file = recordPath()
  const read = () => JSON.parse(fs.readFileSync(file, 'utf8'))
  const record = read()
  return {
    file,
    config: record.config,
    // A deployed contract's address; throws if this environment has not deployed it yet.
    address(name) {
      const address = record.contracts[name]
      if (!address) throw new Error(`${name} is not deployed in ${file}`)
      return address
    },
    // Records a contract as soon as it is deployed, so a run that fails later never loses it.
    save(name, address) {
      const fresh = read()
      fresh.contracts[name] = address
      fs.writeFileSync(file, JSON.stringify(fresh, null, 2) + '\n')
      record.contracts[name] = address
    },
    // Stops before any transaction if the network is not the record's chain.
    async check(ethers) {
      const { chainId } = await ethers.provider.getNetwork()
      if (chainId !== record.chainId) {
        throw new Error(`Connected to chain ${chainId}, but ${file} is for chain ${record.chainId}`)
      }
      console.log('Deployment:', process.env.DEPLOYMENT || '(custom)', `(${path.relative(process.cwd(), file)})`)
    },
  }
}

module.exports = { load }
