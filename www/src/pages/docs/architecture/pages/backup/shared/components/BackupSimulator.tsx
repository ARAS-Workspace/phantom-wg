import React from 'react';
import {
  Grid,
  Column,
  Tile,
  Button,
  StructuredListWrapper,
  StructuredListHead,
  StructuredListRow,
  StructuredListCell,
  StructuredListBody,
  Tag,
} from '@carbon/react';
import { Download, DocumentImport } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks/useLocale';
import './styles/BackupSimulator.scss';

const MOCK_MANIFEST = {
  version: '1.0',
  timestamp: '2026-03-18T10:23:45.123456+00:00',
  wallet: {
    clients: 12,
    subnet: '10.8.0.0/24',
    pool_total: 253,
    pool_assigned: 12,
  },
  exit_store: {
    exits: 2,
    enabled: false,
    active_exit: '',
  },
};

const LABELS: Record<string, Record<string, string>> = {
  tr: {
    export: 'Yedek Al',
    exportDesc: 'Mevcut daemon durumunu taşınabilir arşiv olarak indir.',
    title: 'Yedekleme Önizlemesi',
    filename: 'phantom-backup-2026-03-18.tar',
    filesize: '48.2 KB',
    field: 'Alan',
    value: 'Değer',
    subnet: 'Alt Ağ',
    clients: 'İstemciler',
    exits: 'Exit Sunucuları',
    timestamp: 'Zaman Damgası',
  },
  en: {
    export: 'Export Backup',
    exportDesc: 'Download the current daemon state as a portable archive.',
    title: 'Backup Preview',
    filename: 'phantom-backup-2026-03-18.tar',
    filesize: '48.2 KB',
    field: 'Field',
    value: 'Value',
    subnet: 'Subnet',
    clients: 'Clients',
    exits: 'Exit Servers',
    timestamp: 'Timestamp',
  },
};

const BackupSimulator: React.FC = () => {
  const { locale } = useLocale();
  const l = LABELS[locale] || LABELS.en;
  const m = MOCK_MANIFEST;

  return (
    <Grid className="backup-sim">
      <Column lg={16} md={8} sm={4}>
        <Tile className="backup-sim__tile">
          <p className="backup-sim__title">{l.export}</p>
          <p className="backup-sim__desc">{l.exportDesc}</p>
          <Button renderIcon={Download} size="md" kind="primary" disabled>
            {l.export}
          </Button>
        </Tile>
      </Column>

      <Column lg={16} md={8} sm={4}>
        <Tile className="backup-sim__tile">
          <div className="backup-sim__header">
            <DocumentImport size={24} />
            <p className="backup-sim__title">{l.title}</p>
          </div>

          <div className="backup-sim__file">
            <span className="backup-sim__filename">{l.filename}</span>
            <Tag size="sm" type="gray">{l.filesize}</Tag>
          </div>

          <StructuredListWrapper className="backup-sim__list" isCondensed>
            <StructuredListHead>
              <StructuredListRow head>
                <StructuredListCell head>{l.field}</StructuredListCell>
                <StructuredListCell head>{l.value}</StructuredListCell>
              </StructuredListRow>
            </StructuredListHead>
            <StructuredListBody>
              <StructuredListRow>
                <StructuredListCell>{l.subnet}</StructuredListCell>
                <StructuredListCell>{m.wallet.subnet}</StructuredListCell>
              </StructuredListRow>
              <StructuredListRow>
                <StructuredListCell>{l.clients}</StructuredListCell>
                <StructuredListCell>{m.wallet.clients} / {m.wallet.pool_total}</StructuredListCell>
              </StructuredListRow>
              <StructuredListRow>
                <StructuredListCell>{l.exits}</StructuredListCell>
                <StructuredListCell>{m.exit_store.exits}</StructuredListCell>
              </StructuredListRow>
              <StructuredListRow>
                <StructuredListCell>{l.timestamp}</StructuredListCell>
                <StructuredListCell>{m.timestamp}</StructuredListCell>
              </StructuredListRow>
            </StructuredListBody>
          </StructuredListWrapper>
        </Tile>
      </Column>
    </Grid>
  );
};

export default BackupSimulator;
