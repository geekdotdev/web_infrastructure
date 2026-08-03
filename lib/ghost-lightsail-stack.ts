import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as lightsail from 'aws-cdk-lib/aws-lightsail';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import * as fs from 'fs';
import * as path from 'path';

export interface GhostLightsailStackProps extends cdk.StackProps {
  /** Environment label (dev, qa, prod, ...) suffixed onto every resource name. */
  readonly envLabel: string;
  /** Ghost journal subdomain for this env (dev, qa, ... ; www for prod). */
  readonly journalSubdomain: string;
  /** Full journal domain (e.g. dev.geek.dev); Caddy terminates TLS for it. */
  readonly journalDomainName: string;
  /** ACME registration email Caddy uses with Let's Encrypt. */
  readonly acmeEmail: string;
  /**
   * If non-empty, Caddy also serves this bare apex domain as a permanent
   * redirect to the journal domain (prod only; '' disables).
   */
  readonly apexRedirectDomain?: string;
  /** CloudFront media subdomain for this env (cfmedia-<env>). */
  readonly mediaSubdomain: string;
  /** Full custom domain for the media distribution (cfmedia-<env>.geek.dev). */
  readonly mediaDomainName: string;
  /**
   * ACM cert ARN (us-east-1) covering mediaDomainName. Optional until DNS/TLS
   * exist: without it the alias is omitted and CloudFront serves from its
   * default domain; with it the custom domain is attached.
   */
  readonly mediaCertificateArn?: string;
  /** Lightsail bundle (instance size), e.g. 'medium_3_0' (2 vCPU / 4 GB). */
  readonly bundleId?: string;
  /** Lightsail blueprint (OS image). */
  readonly blueprintId?: string;
  /** Size of the block-storage data disk backing the MySQL LVM volume. */
  readonly dataDiskSizeGb?: number;
  /** Size of the block-storage disk backing the Ghost content LVM volume. */
  readonly contentDiskSizeGb?: number;
  /** Optional Lightsail availability zone, e.g. 'us-east-1a'. Defaults to <region>a. */
  readonly availabilityZone?: string;
  /**
   * PEM-encoded RSA public key (the private half signs CloudFront URLs and
   * cookies). Required so the media distribution only serves signed requests.
   */
  readonly mediaPublicKeyPem: string;
}

/**
 * Single Lightsail instance ("scaled" to exactly 1 — Lightsail has no
 * autoscaling groups) running Ghost CMS + MySQL via podman-compose.
 *
 * MySQL data lives on an LVM logical volume (vg_data/lv_mysql) and Ghost
 * content on a second one (vg_content/lv_content), each created on its own
 * dedicated Lightsail block-storage disk (separate VGs so a disk
 * failure is isolated to one workload). Note: Lightsail instances cannot
 * attach EBS volumes; Lightsail block storage is the equivalent SSD-backed
 * offering and the LVM layout on top is identical.
 */
export class GhostLightsailStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: GhostLightsailStackProps) {
    super(scope, id, props);

    const envLabel = props.envLabel;
    const bundleId = props.bundleId ?? 'medium_3_0';
    const blueprintId = props.blueprintId ?? 'ubuntu_24_04';
    const dataDiskSizeGb = props.dataDiskSizeGb ?? 20;
    const contentDiskSizeGb = props.contentDiskSizeGb ?? 20;
    const az = props.availabilityZone ?? `${this.region}a`;

    const instanceName = `ghost-cms-${envLabel}`;
    const mysqlDiskName = `ghost-mysql-data-${envLabel}`;
    const mysqlDiskPath = '/dev/xvdf';
    const contentDiskName = `ghost-content-data-${envLabel}`;
    const contentDiskPath = '/dev/xvdg';
    const staticIpName = `ghost-cms-ip-${envLabel}`;
    const envTags = [
      { key: 'app', value: 'ghost' },
      { key: 'env', value: envLabel },
    ];

    const deploymentBucketName = `geek-dot-dev-deployment-resources-${envLabel}`;

    // Block-storage disk for MySQL (LVM PV for vg_data).
    const dataDisk = new lightsail.CfnDisk(this, 'MysqlDataDisk', {
      diskName: mysqlDiskName,
      sizeInGb: dataDiskSizeGb,
      availabilityZone: az,
      tags: envTags,
    });

    // Block-storage disk for Ghost content (LVM PV for vg_content).
    const contentDisk = new lightsail.CfnDisk(this, 'ContentDisk', {
      diskName: contentDiskName,
      sizeInGb: contentDiskSizeGb,
      availabilityZone: az,
      tags: envTags,
    });

    const userData = fs
      .readFileSync(path.join(__dirname, '..', 'assets', 'user-data.sh'), 'utf8')
      .replace(/__MYSQL_DISK_PATH__/g, mysqlDiskPath)
      .replace(/__CONTENT_DISK_PATH__/g, contentDiskPath)
      .replace(/__JOURNAL_DOMAIN__/g, props.journalDomainName)
      .replace(/__ACME_EMAIL__/g, props.acmeEmail)
      .replace(/__APEX_REDIRECT_DOMAIN__/g, props.apexRedirectDomain ?? '')
      // Safe to inject before the bucket exists: bucket names are
      // deterministic (account-namespaced since 2020-era S3 rules), and the
      // boot script only records it for later pulls.
      .replace(/__DEPLOYMENT_BUCKET__/g, deploymentBucketName);

    const instance = new lightsail.CfnInstance(this, 'GhostInstance', {
      instanceName,
      availabilityZone: az,
      blueprintId,
      bundleId,
      // Attaching the disk here both declares and performs the attachment.
      hardware: {
        disks: [
          {
            diskName: mysqlDiskName,
            path: mysqlDiskPath,
            attachedTo: instanceName,
            isSystemDisk: false,
          },
          {
            diskName: contentDiskName,
            path: contentDiskPath,
            attachedTo: instanceName,
            isSystemDisk: false,
          },
        ],
      },
      networking: {
        ports: [
          // SSH: no public exposure; reachable only via the Lightsail
          // console's browser-based SSH (the 'lightsail-connect' alias).
          {
            fromPort: 22,
            toPort: 22,
            protocol: 'tcp',
            cidrs: [],
            cidrListAliases: ['lightsail-connect'],
          },
          { fromPort: 80, toPort: 80, protocol: 'tcp' },
          { fromPort: 443, toPort: 443, protocol: 'tcp' },
        ],
      },
      userData,
      tags: envTags,
    });
    instance.addResourceDependency(dataDisk);
    instance.addResourceDependency(contentDisk);

    // Deployment-resources bucket: private per-env config that shouldn't
    // live in the public repo. Created *after* the instance so the
    // resourcesReceivingAccess grant can name it — giving the instance
    // credential-free read access from the moment the bucket exists.
    const deploymentBucket = new lightsail.CfnBucket(this, 'DeploymentBucket', {
      bucketName: deploymentBucketName,
      bundleId: 'small_1_0',
      objectVersioning: true,
      resourcesReceivingAccess: [instanceName],
      tags: envTags,
    });
    deploymentBucket.addResourceDependency(instance);

    const staticIp = new lightsail.CfnStaticIp(this, 'GhostStaticIp', {
      staticIpName,
      attachedTo: instanceName,
    });
    staticIp.addResourceDependency(instance);

    // --- Private media bucket + CloudFront (signed URLs / cookies) ---------

    const mediaBucket = new s3.Bucket(this, 'MediaBucket', {
      bucketName: `geek-dot-dev-media-primary-${envLabel}`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      // Keep prod media if the stack is torn down; dev/qa buckets are
      // deletable (CloudFormation still refuses if non-empty).
      removalPolicy:
        envLabel === 'prod' ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });

    const mediaPublicKey = new cloudfront.PublicKey(this, 'MediaPublicKey', {
      publicKeyName: `ghost-media-key-${envLabel}`,
      encodedKey: props.mediaPublicKeyPem,
      comment: `Verifies signed URLs/cookies for ${envLabel} media`,
    });

    const mediaKeyGroup = new cloudfront.KeyGroup(this, 'MediaKeyGroup', {
      keyGroupName: `ghost-media-keygroup-${envLabel}`,
      items: [mediaPublicKey],
    });

    // Custom domain: CloudFront refuses aliases without a covering cert, so
    // the alias rides in only once mediaCertificateArn appears in
    // environments.json. Until then: default *.cloudfront.net domain.
    const mediaCertificate = props.mediaCertificateArn
      ? acm.Certificate.fromCertificateArn(this, 'MediaCertificate', props.mediaCertificateArn)
      : undefined;

    const mediaDistribution = new cloudfront.Distribution(this, 'MediaDistribution', {
      comment: `ghost media (${envLabel})`,
      ...(mediaCertificate
        ? { domainNames: [props.mediaDomainName], certificate: mediaCertificate }
        : {}),
      defaultBehavior: {
        // OAC: bucket stays private; only this distribution can read it.
        origin: origins.S3BucketOrigin.withOriginAccessControl(mediaBucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        // Requests without a valid signed URL or signed cookie get a 403.
        trustedKeyGroups: [mediaKeyGroup],
      },
    });

    new cdk.CfnOutput(this, 'DeploymentBucketName', {
      value: deploymentBucketName,
      description: 'Lightsail bucket for private per-env deployment configuration',
    });
    new cdk.CfnOutput(this, 'MediaBucketName', { value: mediaBucket.bucketName });
    new cdk.CfnOutput(this, 'MediaDistributionDomain', {
      value: mediaDistribution.distributionDomainName,
      description: 'Default CloudFront domain; CNAME target for the custom media domain',
    });
    new cdk.CfnOutput(this, 'MediaCustomDomain', {
      value: mediaCertificate
        ? `https://${props.mediaDomainName} (alias active)`
        : `${props.mediaDomainName} (pending: set mediaCertificateArn in environments.json)`,
      description: 'Custom media domain served by CloudFront',
    });
    new cdk.CfnOutput(this, 'MediaKeyPairId', {
      value: mediaPublicKey.publicKeyId,
      description: 'Use as CloudFront-Key-Pair-Id when signing URLs/cookies',
    });

    new cdk.CfnOutput(this, 'StaticIpAddress', {
      value: staticIp.attrIpAddress,
      description: 'Public static IP of the Ghost instance',
    });
    new cdk.CfnOutput(this, 'InstanceName', { value: instanceName });
    new cdk.CfnOutput(this, 'JournalSubdomain', {
      value: props.journalSubdomain,
      description: 'Point <journalSubdomain>.<your-domain> at the static IP',
    });
    new cdk.CfnOutput(this, 'MediaSubdomain', {
      value: props.mediaSubdomain,
      description: 'CNAME <mediaSubdomain>.<your-domain> to the CloudFront distribution',
    });
    new cdk.CfnOutput(this, 'SshHint', {
      value: 'Port 22 is not publicly exposed; use browser SSH in the Lightsail console (Connect tab)',
      description: 'SSH access is limited to Lightsail browser-based SSH',
    });
  }
}
