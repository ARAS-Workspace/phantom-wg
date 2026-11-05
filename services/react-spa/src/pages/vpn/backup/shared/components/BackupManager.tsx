import React, { useState, useRef, useCallback } from 'react';
import {
  Grid,
  Column,
  Tile,
  Button,
  InlineNotification,
  InlineLoading,
  StructuredListWrapper,
  StructuredListHead,
  StructuredListRow,
  StructuredListCell,
  StructuredListBody,
  Tag,
} from '@carbon/react';
import {
  Download,
  Upload,
  CheckmarkFilled,
  DocumentImport,
  ArrowLeft,
  Warning,
} from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import FormError from '@shared/components/forms/FormError';
import LoadingSpinner from '@shared/components/ui/LoadingSpinner';
import { formatBytes } from '@shared/utils/formatUtils';
import './styles/BackupManager.scss';

// ── Types ─────────────────────────────────────────────────────────

interface RestoreResult {
  timestamp: string;
  wallet_clients: number;
  wallet_subnet: string;
  exit_count: number;
  exit_enabled: boolean;
}

interface ManifestInfo {
  version: string;
  timestamp: string;
  wallet: {
    clients: number;
    subnet: string;
    pool_total: number;
    pool_assigned: number;
  };
  exit_store: {
    exits: number;
    enabled: boolean;
    active_exit: string;
  };
}

interface FileValidation {
  file: File;
  manifest: ManifestInfo;
  members: string[];
}

type ImportStep = 'idle' | 'validating' | 'preview' | 'importing' | 'done' | 'failed';

// Matches client_max_body_size in nginx.conf and AUTH_PROXY_BACKUP_MAX_BODY.
const MAX_BACKUP_BYTES = 64 * 1024 * 1024;

// ── Component ─────────────────────────────────────────────────────

const BackupManager: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Export state
  const [exporting, setExporting] = useState(false);
  const [exportError, setExportError] = useState<string | null>(null);

  // Import wizard state
  const [importStep, setImportStep] = useState<ImportStep>('idle');
  const [validation, setValidation] = useState<FileValidation | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [restoreResult, setRestoreResult] = useState<RestoreResult | null>(null);

  const apiErrorMessage = (
    body: { code?: string; error_code?: string },
    fallback: string
  ): string =>
    (t.auth_service_api_codes as Record<string, string>)[body.error_code ?? ''] ??
    (t.daemon_api_codes as Record<string, string>)[body.code ?? ''] ??
    fallback;

  // ── Export ────────────────────────────────────────────────────

  const handleExport = async () => {
    setExporting(true);
    setExportError(null);

    try {
      const token = localStorage.getItem('token');
      const resp = await fetch('/api/core/backup/export', {
        method: 'POST',
        headers: { Authorization: `Bearer ${token ?? ''}` },
      });

      if (!resp.ok) {
        const body = await resp.json().catch(() => ({}));
        setExportError(apiErrorMessage(body, t.backup.exportFailed));
        setExporting(false);
        return;
      }

      const blob = await resp.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download =
        resp.headers
          .get('content-disposition')
          ?.match(/filename="?(.+?)"?$/)?.[1] ??
        `phantom-backup-${Date.now()}.tar`;
      a.click();
      URL.revokeObjectURL(url);
    } catch {
      setExportError(t.backup.exportFailed);
    } finally {
      setExporting(false);
    }
  };

  // ── Import wizard ─────────────────────────────────────────────

  const resetImport = useCallback(() => {
    setImportStep('idle');
    setValidation(null);
    setImportError(null);
    setRestoreResult(null);
    if (fileInputRef.current) fileInputRef.current.value = '';
  }, []);

  const handleFileSelect = () => {
    fileInputRef.current?.click();
  };

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    e.target.value = '';

    // Step 1: Client-side validation
    setImportStep('validating');
    setImportError(null);

    const fail = (msg: string) => {
      setImportError(msg);
      setImportStep('failed');
    };

    // Extension check
    if (!file.name.endsWith('.tar')) {
      fail(t.backup.validation.invalidFormat);
      return;
    }

    // Size check
    if (file.size > MAX_BACKUP_BYTES) {
      fail(t.backup.validation.tooLarge);
      return;
    }

    // Read and parse tar in browser
    let buffer: ArrayBuffer;
    try {
      buffer = await file.arrayBuffer();
    } catch {
      fail(t.backup.importFailed);
      return;
    }

    const members = parseTarMembers(buffer);
    const required = ['wallet.db', 'exit.db', 'manifest.json'];
    const missing = required.filter((f) => !members.includes(f));

    if (missing.length > 0) {
      fail(`${t.backup.validation.missingFiles}: ${missing.join(', ')}`);
      return;
    }

    // Extract and parse manifest.json
    const manifestBytes = extractTarFile(buffer, 'manifest.json');
    if (!manifestBytes) {
      fail(t.backup.validation.invalidManifest);
      return;
    }

    let manifest: ManifestInfo;
    try {
      manifest = JSON.parse(new TextDecoder().decode(manifestBytes));
    } catch {
      fail(t.backup.validation.invalidManifest);
      return;
    }

    if (manifest.version !== '1.0') {
      fail(t.backup.validation.unsupportedVersion);
      return;
    }

    if (!manifest.wallet || !manifest.exit_store) {
      fail(t.backup.validation.invalidManifest);
      return;
    }

    // Validation passed — show preview
    setValidation({ file, manifest, members });
    setImportStep('preview');
  };

  const handleConfirmImport = async () => {
    if (!validation) return;

    setImportStep('importing');
    setImportError(null);

    const form = new FormData();
    form.append('file', validation.file);

    try {
      const token = localStorage.getItem('token');
      const resp = await fetch('/api/core/backup/import', {
        method: 'POST',
        headers: { Authorization: `Bearer ${token ?? ''}` },
        body: form,
      });

      const data = await resp.json();

      if (data.ok) {
        setRestoreResult(data.data);
        setImportStep('done');
      } else {
        setImportError(apiErrorMessage(data, t.backup.importFailed));
        setImportStep('failed');
      }
    } catch {
      setImportError(t.backup.importFailed);
      setImportStep('failed');
    }
  };

  // ── Tar parsing (browser-side) ────────────────────────────────

  function parseTarMembers(buffer: ArrayBuffer): string[] {
    const view = new Uint8Array(buffer);
    const names: string[] = [];
    let offset = 0;

    while (offset + 512 <= view.length) {
      const header = view.slice(offset, offset + 512);
      // All zeros = end of archive
      if (header.every((b) => b === 0)) break;

      const name = new TextDecoder()
        .decode(header.slice(0, 100))
        .replace(/\0/g, '')
        .trim();
      if (name) names.push(name);

      // File size from octal field at offset 124, length 12
      const sizeStr = new TextDecoder()
        .decode(header.slice(124, 136))
        .replace(/\0/g, '')
        .trim();
      const size = parseInt(sizeStr, 8) || 0;

      // Skip header + file content (padded to 512-byte blocks)
      offset += 512 + Math.ceil(size / 512) * 512;
    }

    return names;
  }

  function extractTarFile(
    buffer: ArrayBuffer,
    target: string
  ): Uint8Array | null {
    const view = new Uint8Array(buffer);
    let offset = 0;

    while (offset + 512 <= view.length) {
      const header = view.slice(offset, offset + 512);
      if (header.every((b) => b === 0)) break;

      const name = new TextDecoder()
        .decode(header.slice(0, 100))
        .replace(/\0/g, '')
        .trim();

      const sizeStr = new TextDecoder()
        .decode(header.slice(124, 136))
        .replace(/\0/g, '')
        .trim();
      const size = parseInt(sizeStr, 8) || 0;

      if (name === target) {
        return view.slice(offset + 512, offset + 512 + size);
      }

      offset += 512 + Math.ceil(size / 512) * 512;
    }

    return null;
  }

  // ── Render: Import wizard steps ───────────────────────────────

  const renderImportWizard = () => {
    const m = validation?.manifest;

    switch (importStep) {
      case 'idle':
        return (
          <Tile className="backup__tile" data-testid="vpn-backup-tile-import">
            <p className="backup__tile-title">{t.backup.import}</p>
            <p className="backup__tile-description">
              {t.backup.importDescription}
            </p>
            <Button
              renderIcon={Upload}
              size="md"
              kind="tertiary"
              onClick={handleFileSelect}
              data-testid="vpn-backup-import-btn"
            >
              {t.backup.selectFile}
            </Button>
          </Tile>
        );

      case 'validating':
        return (
          <Tile className="backup__tile">
            <InlineLoading description={t.backup.validating} />
          </Tile>
        );

      case 'preview':
        return (
          <Tile
            className="backup__tile backup__tile--preview"
            data-testid="vpn-backup-preview"
          >
            <div className="backup__preview-header">
              <DocumentImport size={24} />
              <p className="backup__tile-title">{t.backup.previewTitle}</p>
            </div>

            <div className="backup__preview-file">
              <span className="backup__preview-filename">
                {validation!.file.name}
              </span>
              <Tag size="sm" type="gray">
                {formatBytes(validation!.file.size)}
              </Tag>
            </div>

            <StructuredListWrapper
              className="backup__preview-list"
              isCondensed
            >
              <StructuredListHead>
                <StructuredListRow head>
                  <StructuredListCell head>{t.backup.field}</StructuredListCell>
                  <StructuredListCell head>{t.backup.value}</StructuredListCell>
                </StructuredListRow>
              </StructuredListHead>
              <StructuredListBody>
                <StructuredListRow>
                  <StructuredListCell>{t.backup.subnet}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-backup-preview-subnet">
                    {m?.wallet.subnet}
                  </StructuredListCell>
                </StructuredListRow>
                <StructuredListRow>
                  <StructuredListCell>{t.backup.clients}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-backup-preview-clients">
                    {m?.wallet.clients} / {m?.wallet.pool_total}
                  </StructuredListCell>
                </StructuredListRow>
                <StructuredListRow>
                  <StructuredListCell>{t.backup.exits}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-backup-preview-exits">
                    {m?.exit_store.exits}
                    {m?.exit_store.enabled && m.exit_store.active_exit && (
                      <Tag size="sm" type="green" className="backup__tag-inline">
                        {m.exit_store.active_exit}
                      </Tag>
                    )}
                  </StructuredListCell>
                </StructuredListRow>
                <StructuredListRow>
                  <StructuredListCell>{t.backup.timestamp}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-backup-preview-timestamp">
                    {m?.timestamp}
                  </StructuredListCell>
                </StructuredListRow>
              </StructuredListBody>
            </StructuredListWrapper>

            <InlineNotification
              kind="warning"
              lowContrast
              hideCloseButton
              title={t.backup.importWarning}
              className="backup__preview-warning"
            />

            <div className="backup__wizard-nav">
              <Button
                renderIcon={ArrowLeft}
                size="md"
                kind="secondary"
                onClick={resetImport}
                data-testid="vpn-backup-cancel-btn"
              >
                {t.backup.cancel}
              </Button>
              <Button
                size="md"
                kind="danger"
                onClick={handleConfirmImport}
                data-testid="vpn-backup-confirm-btn"
              >
                {t.backup.confirmImport}
              </Button>
            </div>
          </Tile>
        );

      case 'importing':
        return (
          <Tile className="backup__tile">
            <LoadingSpinner text={t.backup.importing} />
          </Tile>
        );

      case 'done':
        return (
          <Tile
            className="backup__tile backup__tile--done"
            data-testid="vpn-backup-done"
          >
            <CheckmarkFilled size={48} className="backup__done-icon" />
            <p className="backup__done-title">{t.backup.importSuccess}</p>
            {restoreResult && (
              <p className="backup__done-detail">
                {restoreResult.wallet_clients} {t.backup.clients} ·{' '}
                {restoreResult.wallet_subnet} · {restoreResult.exit_count}{' '}
                {t.backup.exits}
              </p>
            )}
            <Button size="md" kind="primary" onClick={resetImport}>
              {t.backup.backToStart}
            </Button>
          </Tile>
        );

      case 'failed':
        return (
          <Tile className="backup__tile backup__tile--failed">
            <Warning size={48} className="backup__failed-icon" />
            <FormError error={importError} className="backup__notification" />
            <Button
              renderIcon={ArrowLeft}
              size="md"
              kind="secondary"
              onClick={resetImport}
              data-testid="vpn-backup-retry-btn"
            >
              {t.backup.retry}
            </Button>
          </Tile>
        );

      default:
        return null;
    }
  };

  // ── Render ────────────────────────────────────────────────────

  return (
    <>
      <FormError error={exportError} className="backup__notification" />

      <input
        ref={fileInputRef}
        type="file"
        accept=".tar"
        onChange={handleFileChange}
        className="backup__file-input"
        data-testid="vpn-backup-file-input"
      />

      <Grid>
        {/* Export */}
        <Column lg={16} md={8} sm={4}>
          <Tile className="backup__tile" data-testid="vpn-backup-tile-export">
            <p className="backup__tile-title">{t.backup.export}</p>
            <p className="backup__tile-description">
              {t.backup.exportDescription}
            </p>
            {exporting ? (
              <InlineLoading description={t.backup.exporting} />
            ) : (
              <Button
                renderIcon={Download}
                size="md"
                kind="primary"
                onClick={handleExport}
                data-testid="vpn-backup-export-btn"
              >
                {t.backup.export}
              </Button>
            )}
          </Tile>
        </Column>

        {/* Import wizard */}
        <Column lg={16} md={8} sm={4}>
          {renderImportWizard()}
        </Column>
      </Grid>
    </>
  );
};

export default BackupManager;
