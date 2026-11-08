import React from 'react';
import { Tag } from '@carbon/react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { getPeerStatus, type PeerStatus } from '@shared/types/wireguard';

const TAG_TYPE: Record<PeerStatus, 'green' | 'red' | 'gray'> = {
  online: 'green',
  offline: 'red',
  never: 'gray',
};

interface PeerStatusTagProps {
  latestHandshake: number;
}

const PeerStatusTag: React.FC<PeerStatusTagProps> = ({ latestHandshake }) => {
  const { locale } = useLocale();
  const t = translate(locale);
  const status = getPeerStatus(latestHandshake);
  const text: Record<PeerStatus, string> = {
    online: t.wireguard.online,
    offline: t.wireguard.offline,
    never: t.wireguard.neverConnected,
  };

  return (
    <Tag type={TAG_TYPE[status]} size="sm">
      {text[status]}
    </Tag>
  );
};

export default PeerStatusTag;
