import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getRegionProfile } from './regions.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const reviewStages = ['inventory', 'frontend', 'native', 'build', 'package'];

function entryContract({ callSites, ...entry }) {
  return { ...entry, payloadReads: [...new Set(callSites.flatMap(site => site.payloadReads || []))].sort() };
}

export function inventoryChanges(accepted, observed) {
  const diff = key => {
    const before = new Map(accepted[key].map(entry => [entry.name, entryContract(entry)]));
    const after = new Map(observed[key].map(entry => [entry.name, entryContract(entry)]));
    return {
      added: [...after.keys()].filter(name => !before.has(name)),
      removed: [...before.keys()].filter(name => !after.has(name)),
      changed: [...after.keys()].filter(name => before.has(name) && !isDeepStrictEqual(before.get(name), after.get(name))),
    };
  };
  return {
    region: observed.sourceApplication.region,
    acceptedVersion: accepted.sourceApplication.version,
    observedVersion: observed.sourceApplication.version,
    acceptedEntry: accepted.sourceApplication.entryModule,
    observedEntry: observed.sourceApplication.entryModule,
    commands: diff('commands'), events: diff('events'),
    runtimeConstants: { changed: !isDeepStrictEqual(accepted.runtimeConstants, observed.runtimeConstants), accepted: accepted.runtimeConstants, observed: observed.runtimeConstants },
    // Full call-site anchors remain in observed-inventory.json; this summary is not an acceptance gate.
  };
}

export async function writeInventoryReview(projectRoot = root, profile = getRegionProfile()) {
  const { inventoryAssets } = await import('./inventory-contract.mjs');
  const lock = JSON.parse(await readFile(path.join(projectRoot, profile.upstreamLock), 'utf8'));
  const acceptedPath = path.join(projectRoot, 'tests', profile.id === 'cn' ? 'contracts.json' : 'contracts-global.json');
  const accepted = JSON.parse(await readFile(acceptedPath, 'utf8'));
  const observed = inventoryAssets(path.join(projectRoot, profile.frontendDir, 'assets'), { version: lock.version });
  const output = path.join(projectRoot, '.work/upstream-review');
  await mkdir(output, { recursive: true });
  await writeFile(path.join(output, 'observed-inventory.json'), `${JSON.stringify(observed, null, 2)}\n`);
  await writeFile(path.join(output, 'contract-changes.json'), `${JSON.stringify(inventoryChanges(accepted, observed), null, 2)}\n`);
}

export function exactIssueNumber(issues, title) {
  return issues.find(issue => issue.title === title)?.number ?? null;
}

export function updatePullRequestArguments({ profile, version, branch, runUrl, outcomes, snapshot = null, manual = null }) {
  const validated = reviewStages.every(stage => outcomes[stage] === 'success');
  const results = [...reviewStages, ...(outcomes.mirror === undefined ? [] : ['mirror'])].map(stage => `- ${stage}: ${outcomes[stage] || 'skipped'}`).join('\n');
  const paragraphs = [
    `${profile.label}官方资源锁定更新至 ${version}，不修改另一个地区。`,
    validated ? '资源检查、契约测试、Rust 测试、原生构建和 ZIP/DMG 打包均已通过。请完成真人登录、输入权限和联机检查后再合并发布。' : '候选版本尚未通过兼容性验证。此 PR 保持草稿，需要审核接口变化、修复失败项并通过两服 CI 后再合并。',
    results,
  ];
  if (snapshot) {
    paragraphs.push(`契约快照 \`${snapshot.file}\` 已按候选前端重新生成并随本 PR 提交（生成器产物，不是人工判断）：${snapshot.commands} 命令 / ${snapshot.events} 事件 / ${snapshot.dynamicCalls} 处动态调用。命令与事件的增删改见 review artifact 里的 \`contract-changes.json\`。`);
    // 兼容性验证永远跑在"上一份已接受快照"上，所以版本一变，frontend 必然先红。
    // 快照已在 PR 内更新，这里要说清楚：红的是旧基线，不是候选本身。
    if (outcomes.frontend !== 'success') {
      paragraphs.push('注意：「frontend」这一步用的是合并前的旧契约快照，官方一改版本它必然先失败。本 PR 已带上重新生成的快照，请对照 `contract-changes.json` 确认接口差异后标记 ready 并合并——以合并后的 CI 结果为准。');
    }
  }
  if (manual) {
    const { file, application, source, observedEntry } = manual;
    const entryNote = observedEntry === source.main
      ? `候选入口模块仍是 \`${observedEntry}\`，与当前记录一致。`
      : `候选入口模块是 \`${observedEntry}\`，当前记录的是 \`${source.main}\`。`;
    paragraphs.push([
      `\`${file}\` 是手写约束，**未自动修改**——改它等于声明"接受这次接口变化"，留给人判断。`,
      `当前记录：application \`${application}\`；source main \`${source.main}\` / room \`${source.room}\` / login \`${source.login}\` / loginView \`${source.loginView}\`。${entryNote}`,
      '若「frontend」这一步失败，按日志里的报错把 application 与 source 四项改成本次候选的值，再重跑工作流。',
    ].join('\n\n'));
  }
  paragraphs.push(`运行、失败日志及 observed inventory / 契约差异：[Actions](${runUrl})。审阅资料：official-${profile.id}-review；完整验证通过后的安装包：official-${profile.id}-candidate。`);
  const body = paragraphs.join('\n\n');
  return ['pr', 'create', '--base', 'main', '--head', branch, '--title', `同步${profile.label}官方资源 ${version}`, '--body', body, ...(validated ? [] : ['--draft'])];
}

function manualContractHint(projectRoot, profile, observedEntry) {
  const file = path.join('tests', profile.id === 'cn' ? 'network-contract.json' : 'network-contract-global.json');
  const full = path.join(projectRoot, file);
  if (!existsSync(full)) return null;
  const contract = JSON.parse(readFileSync(full, 'utf8'));
  return { file: file.split(path.sep).join('/'), application: contract.application, source: contract.source, observedEntry };
}

export async function openUpdatePullRequest({ projectRoot = root, profile = getRegionProfile(), environment = process.env, execute = execFileSync } = {}) {
  const check = JSON.parse(await readFile(path.join(projectRoot, '.work/upstream-check.json'), 'utf8'));
  if (!/^\d+\.\d+\.\d+$/.test(check.latestVersion) || !/^\d+$/.test(environment.GITHUB_RUN_ID)) throw new Error('Invalid update version or run ID');
  const branch = `codex/official-${profile.id}-${check.latestVersion}-${environment.GITHUB_RUN_ID}`;
  if (!execute('git', ['diff', '--', profile.upstreamLock], { cwd: projectRoot, encoding: 'utf8' }).trim()) return;
  // 快照是可再生的，跟锁文件一起提交；手写的 network-contract 仍然只做提示，不动它。
  // 时机很重要：本函数由工作流最后一步调用，所以前边的 npm test 一定是拿"上一份已接受快照"
  // 跑的——先重生成再验证等于自己跟自己比，那道门就废了。
  const { writeContractSnapshot } = await import('./inventory-contract.mjs');
  const written = writeContractSnapshot(projectRoot, profile);
  const snapshot = written && {
    file: path.relative(projectRoot, written.destination).split(path.sep).join('/'),
    commands: written.inventory.commands.length,
    events: written.inventory.events.length,
    dynamicCalls: written.inventory.dynamicCalls.length,
  };
  const manual = manualContractHint(projectRoot, profile, written?.inventory.sourceApplication.entryModule);
  const run = (command, args) => execute(command, args, { cwd: projectRoot, stdio: 'inherit' });
  run('git', ['switch', '-c', branch]);
  run('git', ['config', 'user.name', 'github-actions[bot]']);
  run('git', ['config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com']);
  run('git', ['add', '--', profile.upstreamLock, ...(snapshot ? [snapshot.file] : [])]);
  run('git', ['commit', '-m', `chore: sync official ${profile.id} resources ${check.latestVersion}`]);
  run('git', ['push', 'origin', branch]);
  const outcomes = Object.fromEntries(reviewStages.map(stage => [stage, environment[`${stage.toUpperCase()}_OUTCOME`]]));
  if (environment.MIRROR_OUTCOME !== undefined) outcomes.mirror = environment.MIRROR_OUTCOME;
  const runUrl = `https://github.com/${environment.GITHUB_REPOSITORY}/actions/runs/${environment.GITHUB_RUN_ID}`;
  run('gh', updatePullRequestArguments({ profile, version: check.latestVersion, branch, runUrl, outcomes, snapshot, manual }));
}

export function reportFailure({ profile = getRegionProfile(), environment = process.env, execute = execFileSync } = {}) {
  const title = `${profile.label}官方同步需要处理`;
  const issues = JSON.parse(execute('gh', ['issue', 'list', '--state', 'open', '--search', `${title} in:title`, '--limit', '100', '--json', 'number,title'], { encoding: 'utf8' }));
  const number = exactIssueNumber(issues, title);
  const runUrl = `https://github.com/${environment.GITHUB_REPOSITORY}/actions/runs/${environment.GITHUB_RUN_ID}`;
  const body = `${profile.label}官方同步或兼容性验证失败，未发布新版本。具体失败步骤、日志和可用审阅资料：${runUrl}`;
  execute('gh', number === null ? ['issue', 'create', '--title', title, '--body', body] : ['issue', 'comment', String(number), '--body', body], { stdio: 'inherit' });
}

async function main(action) {
  if (action === 'inventory') return writeInventoryReview();
  if (action === 'open-pr') return openUpdatePullRequest();
  if (action === 'report') return reportFailure();
  throw new Error(`Unknown upstream review action: ${action}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv[2]).catch(error => { console.error(error.message); process.exitCode = 1; });
}
