#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import * as fs from 'fs';
import * as path from 'path';
import { GhostLightsailStack } from '../lib/ghost-lightsail-stack';

interface EnvConfig {
  account: string;
  /**
   * AWS CLI profile for this env. Credential selection happens in the CDK
   * *CLI*, not this app, so deployment/deploy.sh reads this as the default
   * --profile when none is passed on the command line.
   */
  profile?: string;
  region?: string;
  /** Ghost journal subdomain: same as the env label, except prod = "www". */
  journalSubdomain?: string;
  /** CloudFront media subdomain: "cfmedia-<env>". */
  mediaSubdomain?: string;
  /**
   * ACM certificate ARN covering cfmedia-<env>.geek.dev (must live in
   * us-east-1). Until provided, the distribution serves from its default
   * *.cloudfront.net domain; once set, the custom-domain alias is attached.
   */
  mediaCertificateArn?: string;
  /** Email Caddy registers with Let's Encrypt for the journal's TLS cert. */
  acmeEmail?: string;
  /**
   * MySQL root password for the compose stack. Lives only in this local,
   * gitignored file. NOT consumed by CDK/user data: deployment/deploy.sh
   * pushes it to the deployment bucket post-deploy (as mysql.env) and the
   * instance pulls it at boot — it never appears in the CFN template.
   * Validated here for fail-fast at synth.
   */
  mysqlRootPassword?: string;
}

const ENV_FILE = path.join(__dirname, '..', 'environments.json');

/** Apex domain for all environments; subdomains hang off this. */
const APEX_DOMAIN = 'geek.dev';

const app = new cdk.App();

// --- Required CLI arg: -c env=<label> --------------------------------------
const envLabel: string | undefined = app.node.tryGetContext('env');
if (!envLabel) {
  throw new Error(
    'Missing environment label. Deploy with: npx cdk deploy -c env=<label> (e.g. -c env=dev)',
  );
}
if (!/^[a-z][a-z0-9-]{0,15}$/.test(envLabel)) {
  throw new Error(
    `Invalid env label "${envLabel}": use lowercase alphanumerics/hyphens (it is embedded in AWS resource names).`,
  );
}

// --- Account mapping from local, uncommitted environments.json -------------
if (!fs.existsSync(ENV_FILE)) {
  throw new Error(
    `environments.json not found. Copy environments.json.example to environments.json ` +
      `and fill in the account number for each environment. This file is gitignored on purpose.`,
  );
}
const environments: Record<string, EnvConfig> = JSON.parse(fs.readFileSync(ENV_FILE, 'utf8'));
const envConfig = environments[envLabel];
if (!envConfig?.account) {
  throw new Error(
    `No account mapping for env "${envLabel}" in environments.json. ` +
      `Known envs: ${Object.keys(environments).join(', ') || '(none)'}`,
  );
}

// Subdomain conventions (environments.json can override):
//   journal: env label, except prod -> www
//   media:   cfmedia-<env>
const journalSubdomain =
  envConfig.journalSubdomain ?? (envLabel === 'prod' ? 'www' : envLabel);
const mediaSubdomain = envConfig.mediaSubdomain ?? `cfmedia-${envLabel}`;

// Caddy terminates TLS for the journal and needs an ACME registration email.
if (!envConfig.acmeEmail) {
  throw new Error(
    `Missing "acmeEmail" for env "${envLabel}" in environments.json — ` +
      `Caddy registers this address with Let's Encrypt for the journal's TLS cert.`,
  );
}

// MySQL root password: required, local-only, and must be sane.
if (!envConfig.mysqlRootPassword || envConfig.mysqlRootPassword.length < 16) {
  throw new Error(
    `Missing or too-short "mysqlRootPassword" (min 16 chars) for env "${envLabel}" in environments.json.`,
  );
}
if (!/^[A-Za-z0-9]+$/.test(envConfig.mysqlRootPassword)) {
  throw new Error(
    `"mysqlRootPassword" for env "${envLabel}" must be alphanumeric only — ` +
      `it is embedded in a shell heredoc and compose env file, where special characters break quoting.`,
  );
}

// --- CloudFront signing key (public half only; keys/ is gitignored) --------
const publicKeyPath = path.join(__dirname, '..', 'keys', `${envLabel}-public.pem`);
if (!fs.existsSync(publicKeyPath)) {
  throw new Error(
    `Missing CloudFront public key: keys/${envLabel}-public.pem\n` +
      `Generate a signing key pair for this env:\n` +
      `  mkdir -p keys\n` +
      `  openssl genrsa -out keys/${envLabel}-private.pem 2048\n` +
      `  openssl rsa -pubout -in keys/${envLabel}-private.pem -out keys/${envLabel}-public.pem\n` +
      `The private key stays local (keys/ is gitignored) and is used by your app to sign URLs/cookies.`,
  );
}
const mediaPublicKeyPem = fs.readFileSync(publicKeyPath, 'utf8');

new GhostLightsailStack(app, `GhostLightsailStack-${envLabel}`, {
  env: {
    account: envConfig.account,
    region: envConfig.region ?? 'us-east-1',
  },
  envLabel,
  journalSubdomain,
  journalDomainName: `${journalSubdomain}.${APEX_DOMAIN}`,
  // Bare-apex redirect (geek.dev -> www.geek.dev): prod only, since the
  // apex can only point at one environment. Caddy auto-issues the apex
  // cert when this is set; requires an apex A record to the static IP.
  apexRedirectDomain: envLabel === 'prod' ? APEX_DOMAIN : '',
  acmeEmail: envConfig.acmeEmail,
  mediaSubdomain,
  mediaDomainName: `${mediaSubdomain}.${APEX_DOMAIN}`,
  mediaCertificateArn: envConfig.mediaCertificateArn,
  mediaPublicKeyPem,
  // Ghost + MySQL need headroom; medium = 2 vCPU / 4 GB RAM.
  bundleId: 'medium_3_0',
  // 24.04 ships podman 4.9 + podman-compose in apt (22.04's podman is too old).
  blueprintId: 'ubuntu_24_04',
  dataDiskSizeGb: 20,
  contentDiskSizeGb: 20,
});
