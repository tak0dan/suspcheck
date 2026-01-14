DROP DATABASE IF EXISTS suspicion_check;
CREATE DATABASE IF NOT EXISTS suspicion_check COLLATE utf8mb4_unicode_ci;
USE suspicion_check;

-- =========================
-- Reasoning (MUST COME FIRST)
-- =========================
DROP TABLE IF EXISTS reasoning;
CREATE TABLE reasoning (
  id INT PRIMARY KEY AUTO_INCREMENT,
  hostility_level TINYINT NOT NULL CHECK (hostility_level BETWEEN -3 AND 3),
  is_default BOOLEAN NOT NULL DEFAULT FALSE,
  message TEXT NOT NULL,

  UNIQUE KEY uniq_default_reasoning (hostility_level, is_default)
);

-- Default reasoning per hostility tier
INSERT INTO reasoning (hostility_level, is_default, message) VALUES
(0, TRUE, 'No suspicious origin detected. Green pass.'),
(1, TRUE, 'Suspicious origin detected. Manual confirmation required.'),
(2, TRUE, 'Hostile origin detected. Elevated privileges required.'),
(3, TRUE, 'Origin is explicitly disallowed and blocked.');

-- =========================
-- Countries
-- =========================
DROP TABLE IF EXISTS countries;
CREATE TABLE countries (
  id INT PRIMARY KEY AUTO_INCREMENT,
  iso_code CHAR(2) UNIQUE NOT NULL,
  name VARCHAR(64) NOT NULL,

  -- FIXED: allow full hostility spectrum
  hostility TINYINT NOT NULL CHECK (hostility BETWEEN -3 AND 3),

  reasoning_id INT DEFAULT NULL,
  FOREIGN KEY (reasoning_id) REFERENCES reasoning(id)
);

-- =========================
-- Cities
-- =========================
DROP TABLE IF EXISTS cities;
CREATE TABLE IF NOT EXISTS cities (
  id INT PRIMARY KEY AUTO_INCREMENT,
  country_id INT NOT NULL,
  name VARCHAR(64) NOT NULL,

  -- FIXED: cities should adjust, not override
  hostility_adjustment TINYINT DEFAULT 0 CHECK (hostility_adjustment BETWEEN -3 AND 3),

  FOREIGN KEY (country_id) REFERENCES countries(id)
);

-- =========================
-- Companies
-- =========================
DROP TABLE IF EXISTS companies;
CREATE TABLE companies (
  id INT PRIMARY KEY AUTO_INCREMENT,
  country_id INT NOT NULL,
  name VARCHAR(128) UNIQUE NOT NULL,
  hostility_adjustment TINYINT NOT NULL CHECK (hostility_adjustment BETWEEN -3 AND 3),

  reasoning_id INT DEFAULT NULL,

  FOREIGN KEY (country_id) REFERENCES countries(id),
  FOREIGN KEY (reasoning_id) REFERENCES reasoning(id)
);

-- =========================
-- Structural Tokens (geo / infra)
-- =========================
DROP TABLE IF EXISTS structural_tokens;
CREATE TABLE structural_tokens (
  id INT PRIMARY KEY AUTO_INCREMENT,

  -- token matching is case-insensitive by design
  token VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci UNIQUE NOT NULL,

  hostility_adjustment TINYINT NOT NULL CHECK (hostility_adjustment BETWEEN -3 AND 3),
  reasoning_id INT DEFAULT NULL,

  FOREIGN KEY (reasoning_id) REFERENCES reasoning(id)
);

-- =========================
-- Semantic Tokens (brands / services)
-- =========================
DROP TABLE IF EXISTS semantic_tokens;
CREATE TABLE semantic_tokens (
  id INT PRIMARY KEY AUTO_INCREMENT,

  token VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci UNIQUE NOT NULL,

  hostility_adjustment TINYINT NOT NULL CHECK (hostility_adjustment BETWEEN -3 AND 3),
  company_id INT DEFAULT NULL,
  reasoning_id INT DEFAULT NULL,

  FOREIGN KEY (company_id) REFERENCES companies(id),
  FOREIGN KEY (reasoning_id) REFERENCES reasoning(id)
);

-- =========================
-- Utility Functions
-- =========================
DROP FUNCTION IF EXISTS clamp_hostility;
CREATE FUNCTION clamp_hostility(val INT)
RETURNS INT DETERMINISTIC
RETURN
  CASE
    WHEN val < -3 THEN -3
    WHEN val > 3 THEN 3
    ELSE val
  END;

DROP FUNCTION IF EXISTS hostility_to_enforcement;
CREATE FUNCTION hostility_to_enforcement(val INT)
RETURNS VARCHAR(16) DETERMINISTIC
RETURN
  CASE
    WHEN val <= -1 THEN 'allow'
    WHEN val = 0 THEN 'confirm'
    WHEN val = 1 THEN 'confirm'
    WHEN val = 2 THEN 'privileged'
    WHEN val >= 3 THEN 'deny'
  END;

select * from cities;
ALTER TABLE cities
ADD UNIQUE KEY uniq_city_per_country (country_id, name);
ALTER TABLE companies
DROP INDEX name,
ADD UNIQUE KEY uniq_company_per_country (country_id, name);


DELIMITER //

CREATE PROCEDURE ingest_policy_bundle(IN p_json JSON)
BEGIN
  -- =========================
  -- 1. DECLARATIONS (ALL FIRST)
  -- =========================
  DECLARE v_country_id INT;
  DECLARE v_company_id INT;

  DECLARE done INT DEFAULT 0;
  DECLARE cur_company_name VARCHAR(128);
  DECLARE cur_company_hostility INT;
  DECLARE cur_company_tokens JSON;

  DECLARE company_cursor CURSOR FOR
    SELECT
      jt.name,
      jt.hostility_adjustment,
      jt.semantic_tokens
    FROM JSON_TABLE(p_json, '$.companies[*]'
      COLUMNS (
        name VARCHAR(128) PATH '$.name',
        hostility_adjustment INT PATH '$.hostility_adjustment',
        semantic_tokens JSON PATH '$.semantic_tokens'
      )
    ) jt;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  -- =========================
  -- 2. EXECUTION BEGINS
  -- =========================
  START TRANSACTION;

  -- ---- Country ----
  INSERT INTO countries (iso_code, name, hostility)
  VALUES (
    JSON_UNQUOTE(JSON_EXTRACT(p_json, '$.country.iso_code')),
    JSON_UNQUOTE(JSON_EXTRACT(p_json, '$.country.name')),
    JSON_EXTRACT(p_json, '$.country.hostility')
  )
  ON DUPLICATE KEY UPDATE
    id = LAST_INSERT_ID(id);

  SET v_country_id := LAST_INSERT_ID();

  -- ---- Cities ----
  INSERT INTO cities (country_id, name, hostility_adjustment)
  SELECT
    v_country_id,
    jt.name,
    COALESCE(jt.hostility_adjustment, 0)
  FROM JSON_TABLE(p_json, '$.cities[*]'
    COLUMNS (
      name VARCHAR(64) PATH '$.name',
      hostility_adjustment INT PATH '$.hostility_adjustment'
    )
  ) jt
  ON DUPLICATE KEY UPDATE id = id;

  -- ---- Companies ----
  OPEN company_cursor;

  company_loop:
  LOOP
    FETCH company_cursor
      INTO cur_company_name, cur_company_hostility, cur_company_tokens;

    IF done THEN
      LEAVE company_loop;
    END IF;

    INSERT INTO companies (country_id, name, hostility_adjustment)
    VALUES (v_country_id, cur_company_name, cur_company_hostility)
    ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id);

    SET v_company_id := LAST_INSERT_ID();

    IF cur_company_tokens IS NOT NULL THEN
      INSERT INTO semantic_tokens (token, hostility_adjustment, company_id)
      SELECT
        jt.token,
        jt.hostility_adjustment,
        v_company_id
      FROM JSON_TABLE(cur_company_tokens, '$[*]'
        COLUMNS (
          token VARCHAR(64) PATH '$.token',
          hostility_adjustment INT PATH '$.hostility_adjustment'
        )
      ) jt
      ON DUPLICATE KEY UPDATE id = id;
    END IF;

  END LOOP;

  CLOSE company_cursor;

  -- ---- Global semantic tokens ----
  INSERT INTO semantic_tokens (token, hostility_adjustment)
  SELECT
    jt.token,
    jt.hostility_adjustment
  FROM JSON_TABLE(p_json, '$.semantic_tokens[*]'
    COLUMNS (
      token VARCHAR(64) PATH '$.token',
      hostility_adjustment INT PATH '$.hostility_adjustment'
    )
  ) jt
  ON DUPLICATE KEY UPDATE id = id;

  -- ---- Structural tokens ----
  INSERT INTO structural_tokens (token, hostility_adjustment)
  SELECT
    jt.token,
    jt.hostility_adjustment
  FROM JSON_TABLE(p_json, '$.structural_tokens[*]'
    COLUMNS (
      token VARCHAR(64) PATH '$.token',
      hostility_adjustment INT PATH '$.hostility_adjustment'
    )
  ) jt
  ON DUPLICATE KEY UPDATE id = id;


  COMMIT;
END //

DELIMITER ;

