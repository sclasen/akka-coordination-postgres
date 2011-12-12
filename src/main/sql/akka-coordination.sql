CREATE TYPE node_type as ENUM('PERSISTENT', 'EPHEMERAL', 'EPHEMERAL_SEQUENTIAL');

CREATE TABLE AKKA_COORDINATION(path varchar(1024) PRIMARY KEY, value bytea, node node_type, creator varchar(36), updated timestamp with time zone, timeout interval hour to second, version bigint not null default(1));

CREATE TABLE AKKA_COORDINATION_PATHS(path varchar(1024) PRIMARY KEY, parent varchar(1024));

CREATE TABLE AKKA_EPHEMERAL_CLEANER(txid bigint PRIMARY KEY);

CREATE TABLE AKKA_EPHEMERAL_SEQUENTIAL(path varchar(1024) PRIMARY KEY, counter bigint default 1);


CREATE OR REPLACE FUNCTION create_persistent(varchar(1024), bytea, varchar(36), interval)  RETURNS TEXT AS $$
DECLARE
    _path ALIAS FOR $1;
    _val ALIAS FOR $2;
    _creator ALIAS FOR $3;
    _timeout ALIAS FOR $4;
BEGIN
    INSERT INTO AKKA_COORDINATION(PATH, VALUE, NODE, CREATOR, UPDATED, TIMEOUT) values(_path,_val,'PERSISTENT',_creator, CURRENT_TIMESTAMP, _timeout); 
    RETURN _path;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION create_ephemeral(varchar(1024), bytea, varchar(36), interval)  RETURNS TEXT AS $$
DECLARE
    _path ALIAS FOR $1;
    _val ALIAS FOR $2;
    _creator ALIAS FOR $3;
    _timeout ALIAS FOR $4;
BEGIN
    INSERT INTO AKKA_COORDINATION(PATH, VALUE, NODE, CREATOR, UPDATED, TIMEOUT) values(_path,_val,'EPHEMERAL', _creator, CURRENT_TIMESTAMP, _timeout);
    RETURN _path;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION create_ephemeral_sequential(varchar(1024), bytea, varchar(36), interval)  RETURNS TEXT AS $$
DECLARE
    _path ALIAS FOR $1;
    _val ALIAS FOR $2;
    _creator ALIAS FOR $3;
    _timeout ALIAS FOR $4;
    _seq bigint;
    _exists boolean;
    _fullpath text;
BEGIN
    select exists(select path from AKKA_EPHEMERAL_SEQUENTIAL where path = _path) into _exists;
    IF(_exists) THEN
      SELECT counter + 1 FROM AKKA_EPHEMERAL_SEQUENTIAL where path = _path FOR UPDATE into _seq;
      UPDATE AKKA_EPHEMERAL_SEQUENTIAL SET counter = _seq where PATH = _path;
    ELSE
      INSERT INTO AKKA_EPHEMERAL_SEQUENTIAL (PATH, COUNTER) VALUES (_path, 1);
      _seq := 1;
    END IF;
      _fullpath := _path || '_' || lpad(CAST(_seq as TEXT), 10, '0');
      INSERT INTO AKKA_COORDINATION(PATH, VALUE, NODE, CREATOR, UPDATED, TIMEOUT) values(_fullpath, _val,'EPHEMERAL_SEQUENTIAL', _creator, CURRENT_TIMESTAMP, _timeout);
    RETURN _fullpath;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION update_node(varchar(1024), bytea, bigint)  RETURNS BIGINT AS $$
DECLARE
    _path ALIAS FOR $1;
    _val ALIAS FOR $2;
    _curr ALIAS FOR $3;
    _ver bigint;
BEGIN
    SELECT version  FROM AKKA_COORDINATION  where path = _path FOR UPDATE into _ver;
    IF NOT FOUND THEN 
        RAISE SQLSTATE '02000' USING MESSAGE = 'Missing Data for ' || _path;
    END IF;
    IF(_curr != NULL OR _curr != _ver) THEN
        RAISE SQLSTATE '2F002' USING MESSAGE = 'Bad Version Specified for ' || _path;
    END IF;
    
    UPDATE AKKA_COORDINATION SET VALUE = _val, VERSION = _ver + 1 where PATH = _path;
    RETURN _ver;
END;
$$ LANGUAGE plpgsql;

 

CREATE OR REPLACE FUNCTION find_parent(text) RETURNS TEXT AS $$
DECLARE
    child ALIAS FOR $1;
    childpath text[];
    depth integer;
BEGIN
    childpath := string_to_array(child, '/'); 
    depth := array_length(childpath,1);
    RETURN array_to_string(childpath[1:depth-1], '/');
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION node_siblings(text) RETURNS TEXT AS $$
DECLARE
    child ALIAS FOR $1;
    siblings text;
BEGIN
    select '/' || STRING_AGG(path, '|/' ORDER BY path) into siblings as children from AKKA_COORDINATION_PATHS where parent = find_parent(child);
    RETURN siblings;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION process_notify_child_listeners() RETURNS trigger AS $process_notify_child_listeners$
    DECLARE
       node text;
    BEGIN
       IF (TG_OP = 'DELETE') THEN
                node := substring(OLD.path from 2);
                PERFORM pg_notify('/' || find_parent(node), node_siblings(node));
                PERFORM pg_notify(node, NULL);
            RETURN OLD;
        ELSIF(TG_OP = 'UPDATE') THEN
            RETURN NEW;
        ELSIF (TG_OP = 'INSERT') THEN
                node := substring(NEW.path from 2);
                PERFORM pg_notify('/' || find_parent(node), node_siblings(node));
                RETURN NEW;
        END IF;
    END;
$process_notify_child_listeners$ LANGUAGE plpgsql VOLATILE;


CREATE TRIGGER notify_child_listeners 
AFTER INSERT OR UPDATE OR DELETE ON AKKA_COORDINATION
    FOR EACH ROW EXECUTE PROCEDURE process_notify_child_listeners();


CREATE OR REPLACE FUNCTION process_ephemerals() RETURNS TRIGGER as $process_ephemerals$
DECLARE
    cleaning boolean;
BEGIN
        select exists(select txid from akka_ephemeral_cleaner where txid = txid_current()) into cleaning;
        IF (cleaning) THEN
            RETURN NULL;
        END IF;
        insert into AKKA_EPHEMERAL_CLEANER values (txid_current());
        DELETE FROM AKKA_COORDINATION WHERE node != 'PERSISTENT' AND (updated + timeout) < CURRENT_TIMESTAMP;
        delete from AKKA_EPHEMERAL_CLEANER where txid = txid_current();
        RETURN NULL;
END;
$process_ephemerals$ LANGUAGE plpgsql VOLATILE;



CREATE  TRIGGER ephemerals 
BEFORE INSERT OR UPDATE OR DELETE ON AKKA_COORDINATION
    EXECUTE PROCEDURE process_ephemerals();


CREATE OR REPLACE FUNCTION process_path_insert() RETURNS trigger AS $process_path_insert$
DECLARE
  pathNoSlash text;
BEGIN
  IF(substring(NEW.path from 1 for 1) != '/') THEN
      RAISE 'Illegal path format (%), paths must begin with /', NEW.path;       
  END IF;
  pathNoSlash := substring(NEW.path from 2);
  INSERT INTO AKKA_COORDINATION_PATHS VALUES(pathNoSlash, find_parent(pathNoSlash));
  RETURN NEW;
END;
$process_path_insert$ LANGUAGE plpgsql VOLATILE;
 
CREATE TRIGGER path_insert 
BEFORE INSERT ON AKKA_COORDINATION
    FOR EACH ROW EXECUTE PROCEDURE process_path_insert();   
    
CREATE OR REPLACE FUNCTION process_path_delete() RETURNS trigger AS $process_path_delete$
BEGIN
  DELETE FROM AKKA_COORDINATION_PATHS WHERE PATH = substring(OLD.path from 2);
  RETURN OLD;
END;
$process_path_delete$ LANGUAGE plpgsql VOLATILE;
 
CREATE TRIGGER path_delete
BEFORE DELETE ON AKKA_COORDINATION
    FOR EACH ROW EXECUTE PROCEDURE process_path_delete();