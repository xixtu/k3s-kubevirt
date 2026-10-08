-- ============================================================
-- Apache Guacamole - Seed connexions & groupes AD
-- ============================================================
-- Groupes AD (OU=Technical,OU=groups,OU=CORP,DC=corp,DC=lcl) :
--   GRP_Guac_Admins    -> Administration Guacamole
--   GRP_Guac_DC1       -> Acces RDP a dc1 (192.168.0.100)
--   GRP_Guac_K3S1      -> Acces SSH a k3s-node-1 (192.168.0.11)
-- ============================================================

-- Groupe organisationnel racine
INSERT INTO guacamole_connection_group (connection_group_name, type)
VALUES ('Serveurs', 'ORGANIZATIONAL')
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------
-- Connexion RDP : dc1
-- -----------------------------------------------------------
INSERT INTO guacamole_connection (connection_name, protocol, parent_id, max_connections, max_connections_per_user)
VALUES (
  'dc1 - 192.168.0.100 (RDP)',
  'rdp',
  (SELECT connection_group_id FROM guacamole_connection_group WHERE connection_group_name = 'Serveurs'),
  5,
  2
);

INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT c.connection_id, p.param_name, p.param_value
FROM guacamole_connection c
CROSS JOIN (VALUES
  ('hostname',              '192.168.0.100'),
  ('port',                  '3389'),
  ('security',              'nla'),
  ('ignore-cert',           'true'),
  ('enable-drive',          'false'),
  ('enable-wallpaper',      'false'),
  ('enable-font-smoothing', 'true'),
  ('resize-method',         'display-update'),
  ('color-depth',           '24'),
  ('timezone',              'Europe/Paris')
) AS p(param_name, param_value)
WHERE c.connection_name = 'dc1 - 192.168.0.100 (RDP)';

-- -----------------------------------------------------------
-- Connexion SSH : k3s-node-1
-- -----------------------------------------------------------
INSERT INTO guacamole_connection (connection_name, protocol, parent_id, max_connections, max_connections_per_user)
VALUES (
  'k3s-node-1 - 192.168.0.11 (SSH)',
  'ssh',
  (SELECT connection_group_id FROM guacamole_connection_group WHERE connection_group_name = 'Serveurs'),
  10,
  3
);

INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT c.connection_id, p.param_name, p.param_value
FROM guacamole_connection c
CROSS JOIN (VALUES
  ('hostname',    '192.168.0.11'),
  ('port',        '22'),
  ('color-scheme', 'gray-black'),
  ('font-size',   '14'),
  ('timezone',    'Europe/Paris'),
  ('terminal-type', 'xterm-256color')
) AS p(param_name, param_value)
WHERE c.connection_name = 'k3s-node-1 - 192.168.0.11 (SSH)';

-- -----------------------------------------------------------
-- Groupes utilisateurs (mappage AD)
-- -----------------------------------------------------------

-- GRP_Guac_Admins
INSERT INTO guacamole_entity (name, type) VALUES ('GRP_Guac_Admins', 'USER_GROUP');
INSERT INTO guacamole_user_group (entity_id)
VALUES ((SELECT entity_id FROM guacamole_entity WHERE name = 'GRP_Guac_Admins' AND type = 'USER_GROUP'));

-- GRP_Guac_DC1
INSERT INTO guacamole_entity (name, type) VALUES ('GRP_Guac_DC1', 'USER_GROUP');
INSERT INTO guacamole_user_group (entity_id)
VALUES ((SELECT entity_id FROM guacamole_entity WHERE name = 'GRP_Guac_DC1' AND type = 'USER_GROUP'));

-- GRP_Guac_K3S1
INSERT INTO guacamole_entity (name, type) VALUES ('GRP_Guac_K3S1', 'USER_GROUP');
INSERT INTO guacamole_user_group (entity_id)
VALUES ((SELECT entity_id FROM guacamole_entity WHERE name = 'GRP_Guac_K3S1' AND type = 'USER_GROUP'));

-- -----------------------------------------------------------
-- Permissions admin pour GRP_Guac_Admins
-- -----------------------------------------------------------
INSERT INTO guacamole_system_permission (entity_id, permission)
SELECT e.entity_id, p.perm::guacamole_system_permission_type
FROM guacamole_entity e
CROSS JOIN (VALUES
  ('CREATE_CONNECTION'),
  ('CREATE_CONNECTION_GROUP'),
  ('CREATE_USER'),
  ('CREATE_USER_GROUP'),
  ('ADMINISTER')
) AS p(perm)
WHERE e.name = 'GRP_Guac_Admins' AND e.type = 'USER_GROUP';

-- Admins voient toutes les connexions
INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
SELECT e.entity_id, c.connection_id, 'READ'::guacamole_object_permission_type
FROM guacamole_entity e
CROSS JOIN guacamole_connection c
WHERE e.name = 'GRP_Guac_Admins' AND e.type = 'USER_GROUP';

-- -----------------------------------------------------------
-- Permissions par groupe cible
-- -----------------------------------------------------------

-- GRP_Guac_DC1 -> dc1 RDP
INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
SELECT e.entity_id, c.connection_id, 'READ'::guacamole_object_permission_type
FROM guacamole_entity e, guacamole_connection c
WHERE e.name = 'GRP_Guac_DC1' AND e.type = 'USER_GROUP'
  AND c.connection_name = 'dc1 - 192.168.0.100 (RDP)';

-- GRP_Guac_K3S1 -> k3s-node-1 SSH
INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
SELECT e.entity_id, c.connection_id, 'READ'::guacamole_object_permission_type
FROM guacamole_entity e, guacamole_connection c
WHERE e.name = 'GRP_Guac_K3S1' AND e.type = 'USER_GROUP'
  AND c.connection_name = 'k3s-node-1 - 192.168.0.11 (SSH)';

-- Permissions sur le groupe de connexions "Serveurs"
INSERT INTO guacamole_connection_group_permission (entity_id, connection_group_id, permission)
SELECT e.entity_id, cg.connection_group_id, 'READ'::guacamole_object_permission_type
FROM guacamole_entity e, guacamole_connection_group cg
WHERE e.type = 'USER_GROUP'
  AND e.name IN ('GRP_Guac_Admins', 'GRP_Guac_DC1', 'GRP_Guac_K3S1')
  AND cg.connection_group_name = 'Serveurs';
