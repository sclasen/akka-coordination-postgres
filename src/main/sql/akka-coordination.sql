POSTGRES COORDINATION

KEY (LTREE:PK)      |  VALUE(BLOB)  | TYPE(DEFAULT:PERSISTENT)  | CREATOR(SESSIONID)    | UPDATED(TIMESTAMP) | TIMEOUT(DEFAULT 1MIN)

/path/to/persistent   FOO               PERSISTENT                  123123123123            123                     -1
/path/to/ephemeral    BAR               EPHEMERAL                   123123123               123                     1

CONNECTION LISTENER->JDBC
NODE LISTENER->
LISTEN->

CREATE TYPE node_type as ENUM('PERSISTENT', 'EPHEMERAL', 'EPHEMERAL_SEQUENTIAL')

CREATE TABLE AKKA_COORDINATION(path ltree PRIMARY KEY, value bytea, node node_type, creator varchar(20), updated timestamp with time zone, timeout interval hour to second);

CREATE TABLE AKKA_EPHEMERAL_CLEANER(txid bigint PRIMARY KEY);

//CREATE INDEX AKKA_EPHEMERAL_TIMEOUT ON AKKA_COORDINATION((updated + timeout));

CREATE INDEX AKKA_NODE_DEPTH ON AKKA_COORDINATION(nlevel(path));

CREATE OR REPLACE FUNCTION parent_as_text(ltree) RETURNS TEXT AS $$
DECLARE
    child ALIAS FOR $1;
    depth integer;
BEGIN
    depth := nlevel(child);
    RETURN ltree2text( subltree(child, 0, nlevel(child) -1 ) );
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION siblings_as_text(ltree) RETURNS TEXT AS $$
DECLARE
    child ALIAS FOR $1;
    depth integer;
    siblings text;
BEGIN
    depth := nlevel(child);
    select STRING_AGG(ltree2text(path), '|' ORDER BY path) into siblings as children from AKKA_COORDINATION where nlevel(path) = depth AND path <@ subltree(child, 0, depth-1);
    RETURN siblings;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION process_notify_child_listeners() RETURNS trigger AS $process_notify_child_listeners$
    BEGIN
       IF (TG_OP = 'DELETE') THEN
            IF(nlevel(OLD.PATH) > 1) THEN
                PERFORM pg_notify(parent_as_text(OLD.path), siblings_as_text(OLD.path));
                PERFORM pg_notify(ltree2text(OLD.path), NULL);
            END IF;
            RETURN OLD;
        ELSIF (TG_OP = 'UPDATE') THEN
            IF(nlevel(NEW.PATH) > 1) THEN
                PERFORM pg_notify(parent_as_text(NEW.path), siblings_as_text(NEW.path));
            END IF;
            RETURN NEW;
        ELSIF (TG_OP = 'INSERT') THEN
            IF(nlevel(NEW.PATH) > 1) THEN
                PERFORM pg_notify(parent_as_text(NEW.path), siblings_as_text(NEW.path));
            END IF;
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
        DELETE FROM AKKA_COORDINATION WHERE node != 'PERSISTENT' AND updated + timeout < CURRENT_TIMESTAMP;
        delete from AKKA_EPHEMERAL_CLEANER where txid = txid_current();
        RETURN NULL;
END;
$process_ephemerals$ LANGUAGE plpgsql VOLATILE;

CREATE TRIGGER ephemerals 
BEFORE INSERT OR UPDATE OR DELETE ON AKKA_COORDINATION
    EXECUTE PROCEDURE process_ephemerals();

    
    
    



    
    