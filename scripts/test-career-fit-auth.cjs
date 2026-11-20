const fs = require('node:fs')
const path = require('node:path')
const root = path.resolve(__dirname, '..')
const { spawnSync } = require('node:child_process')
const source = fs.readFileSync(path.join(root, 'server/test/career_fit_authentication_test.rb')).toString('base64')
const result = spawnSync('npx', ['spree', 'exec', '--', 'ruby', '-rbase64', '-e',
  'source = Base64.decode64(ARGV.shift); eval(source, TOPLEVEL_BINDING, "/rails/test/career_fit_authentication_test.rb")', source],
  { cwd: root, stdio: 'inherit' })
process.exit(result.status ?? 1)
