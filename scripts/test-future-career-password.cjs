const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const root = path.resolve(__dirname, '..')
const source = fs.readFileSync(path.join(root, 'server/test/future_career_customer_password_test.rb')).toString('base64')
const result = spawnSync('bunx', ['--bun', 'spree', 'exec', '--', 'ruby', '-rbase64', '-e',
  'source = Base64.decode64(ARGV.shift); eval(source, TOPLEVEL_BINDING, "/rails/test/future_career_customer_password_test.rb")', source],
  { cwd: root, stdio: 'inherit' })
process.exit(result.status ?? 1)
