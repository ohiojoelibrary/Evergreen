BEGIN;

INSERT INTO config.upgrade_log (version) VALUES ('0136'); -- miker

CREATE TABLE config.biblio_fingerprint (
	id			SERIAL	PRIMARY KEY,
	name		TEXT	NOT NULL, 
	xpath		TEXT	NOT NULL,
    first_word  BOOL    NOT NULL DEFAULT FALSE,
	format		TEXT	NOT NULL DEFAULT 'marcxml'
);

INSERT INTO config.biblio_fingerprint (name, xpath, format)
    VALUES (
        'Title',
        '//marc:datafield[@tag="700"]/marc:subfield[@code="t"]|' ||
            '//marc:datafield[@tag="240"]/marc:subfield[@code="a"]|' ||
            '//marc:datafield[@tag="242"]/marc:subfield[@code="a"]|' ||
            '//marc:datafield[@tag="246"]/marc:subfield[@code="a"]|' ||
            '//marc:datafield[@tag="245"]/marc:subfield[@code="a"]',
        'marcxml'
    );

INSERT INTO config.biblio_fingerprint (name, xpath, format, first_word)
    VALUES (
        'Author',
        '//marc:datafield[@tag="700" and ./*[@code="t"]]/marc:subfield[@code="a"]|'
            '//marc:datafield[@tag="100"]/marc:subfield[@code="a"]|'
            '//marc:datafield[@tag="110"]/marc:subfield[@code="a"]|'
            '//marc:datafield[@tag="111"]/marc:subfield[@code="a"]|'
            '//marc:datafield[@tag="260"]/marc:subfield[@code="b"]',
        'marcxml',
        TRUE
    );

CREATE OR REPLACE FUNCTION biblio.extract_quality ( marc TEXT, best_lang TEXT, best_type TEXT ) RETURNS INT AS $func$
DECLARE
    qual        INT;
    ldr         TEXT;
    tval        TEXT;
    tval_rec    RECORD;
    bval        TEXT;
    bval_rec    RECORD;
    type_map    RECORD;
    ff_pos      RECORD;
    ff_tag_data TEXT;
BEGIN

    IF marc IS NULL OR marc = '' THEN
        RETURN NULL;
    END IF;

    -- First, the count of tags
    qual := ARRAY_UPPER(oils_xpath('*[local-name()="datafield"]', marc), 1);

    -- now go through a bunch of pain to get the record type
    IF best_type IS NOT NULL THEN
        ldr := (oils_xpath('//*[local-name()="leader"]/text()', marc))[1];

        IF ldr IS NOT NULL THEN
            SELECT * INTO tval_rec FROM config.marc21_ff_pos_map WHERE fixed_field = 'Type' LIMIT 1; -- They're all the same
            SELECT * INTO bval_rec FROM config.marc21_ff_pos_map WHERE fixed_field = 'BLvl' LIMIT 1; -- They're all the same


            tval := SUBSTRING( ldr, tval_rec.start_pos + 1, tval_rec.length );
            bval := SUBSTRING( ldr, bval_rec.start_pos + 1, bval_rec.length );

            -- RAISE NOTICE 'type %, blvl %, ldr %', tval, bval, ldr;

            SELECT * INTO type_map FROM config.marc21_rec_type_map WHERE type_val LIKE '%' || tval || '%' AND blvl_val LIKE '%' || bval || '%';

            IF type_map.code IS NOT NULL THEN
                IF best_type = type_map.code THEN
                    qual := qual + qual / 2;
                END IF;

                FOR ff_pos IN SELECT * FROM config.marc21_ff_pos_map WHERE fixed_field = 'Lang' AND rec_type = type_map.code ORDER BY tag DESC LOOP
                    ff_tag_data := SUBSTRING((oils_xpath('//*[@tag="' || ff_pos.tag || '"]/text()',marc))[1], ff_pos.start_pos + 1, ff_pos.length);
                    IF ff_tag_data = best_lang THEN
                            qual := qual + 100;
                    END IF;
                END LOOP;
            END IF;
        END IF;
    END IF;

    -- Now look for some quality metrics
    -- DCL record?
    IF ARRAY_UPPER(oils_xpath('//*[@tag="040"]/*[@code="a" and contains(.,"DLC")]', marc), 1) = 1 THEN
        qual := qual + 10;
    END IF;

    -- From OCLC?
    IF (oils_xpath('//*[@tag="003"]/text()', marc))[1] ~* E'oclo?c' THEN
        qual := qual + 10;
    END IF;

    RETURN qual;

END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION biblio.extract_fingerprint ( marc text ) RETURNS TEXT AS $func$
DECLARE
	idx		config.biblio_fingerprint%ROWTYPE;
	xfrm		config.xml_transform%ROWTYPE;
	prev_xfrm	TEXT;
	transformed_xml	TEXT;
	xml_node	TEXT;
	xml_node_list	TEXT[];
	raw_text	TEXT;
    output_text TEXT := '';
BEGIN

    IF marc IS NULL OR marc = '' THEN
        RETURN NULL;
    END IF;

	-- Loop over the indexing entries
	FOR idx IN SELECT * FROM config.biblio_fingerprint ORDER BY format, id LOOP

		SELECT INTO xfrm * from config.xml_transform WHERE name = idx.format;

		-- See if we can skip the XSLT ... it's expensive
		IF prev_xfrm IS NULL OR prev_xfrm <> xfrm.name THEN
			-- Can't skip the transform
			IF xfrm.xslt <> '---' THEN
				transformed_xml := xslt_process(marc,xfrm.xslt);
			ELSE
				transformed_xml := marc;
			END IF;

			prev_xfrm := xfrm.name;
		END IF;

		raw_text := COALESCE(
            naco_normalize(
                ARRAY_TO_STRING(
                    oils_xpath(
                        '//text()',
                        (oils_xpath(
                            idx.xpath,
                            transformed_xml,
                            ARRAY[ARRAY[xfrm.prefix, xfrm.namespace_uri]] 
                        ))[1]
                    ),
                    ''
                )
            ),
            ''
        );

        raw_text := REGEXP_REPLACE(raw_text, E'\\[.+?\\]', E'');
        raw_text := REGEXP_REPLACE(raw_text, E'\\mthe\\M|\\man?d?d\\M', E'', 'g'); -- arg! the pain!

        IF idx.first_word IS TRUE THEN
            raw_text := REGEXP_REPLACE(raw_text, E'^(\\w+).*?$', E'\\1');
        END IF;

		output_text := output_text || REGEXP_REPLACE(raw_text, E'\\s+', '', 'g');

	END LOOP;

    RETURN output_text;

END;
$func$ LANGUAGE PLPGSQL;

-- BEFORE UPDATE OR INSERT trigger for biblio.record_entry
CREATE OR REPLACE FUNCTION biblio.fingerprint_trigger () RETURNS TRIGGER AS $func$
BEGIN

    -- For TG_ARGV, first param is language (like 'eng'), second is record type (like 'BKS')

    IF NEW.deleted IS TRUE THEN -- we don't much care, then, do we?
        RETURN NEW;
    END IF;

    NEW.fingerprint := biblio.extract_fingerprint(NEW.marc);
    NEW.quality := biblio.extract_quality(NEW.marc, TG_ARGV[0], TG_ARGV[1]);

    RETURN NEW;

END;
$func$ LANGUAGE PLPGSQL;

-- AFTER UPDATE OR INSERT trigger for biblio.record_entry
CREATE OR REPLACE FUNCTION biblio.indexing_ingest_or_delete () RETURNS TRIGGER AS $func$
DECLARE
    ind_data        metabib.field_entry_template%ROWTYPE;
    old_mr          INT;
    tmp_mr          metabib.metarecord%ROWTYPE;
    source_count    INT;
    deleted_mrs     INT[];
    uris            TEXT[];
    uri_xml         TEXT;
    uri_label       TEXT;
    uri_href        TEXT;
    uri_use         TEXT;
    uri_owner       TEXT;
    uri_owner_id    INT;
    uri_id          INT;
    uri_cn_id       INT;
    uri_map_id      INT;
BEGIN

    DELETE FROM metabib.metarecord_source_map WHERE source = NEW.id; -- Rid ourselves of the search-estimate-killing linkage

    IF NEW.deleted IS TRUE THEN
        RETURN NEW; -- and we're done
    END IF;

    IF TG_OP = 'UPDATE' THEN -- Clean out the cruft
        DELETE FROM metabib.title_field_entry WHERE source = NEW.id;
        DELETE FROM metabib.author_field_entry WHERE source = NEW.id;
        DELETE FROM metabib.subject_field_entry WHERE source = NEW.id;
        DELETE FROM metabib.keyword_field_entry WHERE source = NEW.id;
        DELETE FROM metabib.series_field_entry WHERE source = NEW.id;
        DELETE FROM metabib.full_rec WHERE record = NEW.id;
        DELETE FROM metabib.rec_descriptor WHERE record = NEW.id;

    END IF;

    -- Shove the flattened MARC in
    INSERT INTO metabib.full_rec (record, tag, ind1, ind2, subfield, value)
        SELECT record, tag, ind1, ind2, subfield, value FROM biblio.flatten_marc( NEW.id );

    -- And now the indexing data
    FOR ind_data IN SELECT * FROM biblio.extract_metabib_field_entry( NEW.id ) LOOP
        IF ind_data.field_class = 'title' THEN
            INSERT INTO metabib.title_field_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        ELSIF ind_data.field_class = 'author' THEN
            INSERT INTO metabib.author_field_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        ELSIF ind_data.field_class = 'subject' THEN
            INSERT INTO metabib.subject_field_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        ELSIF ind_data.field_class = 'keyword' THEN
            INSERT INTO metabib.keyword_field_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        ELSIF ind_data.field_class = 'series' THEN
            INSERT INTO metabib.series_field_entry (field, source, value)
                VALUES (ind_data.field, ind_data.source, ind_data.value);
        END IF;
    END LOOP;

    -- Then, the rec_descriptor
    INSERT INTO metabib.rec_descriptor (record, item_type, item_form, bib_level, control_type, enc_level, audience, lit_form, type_mat, cat_form, pub_status, item_lang, vr_format, date1, date2)
        SELECT  NEW.id,
                biblio.marc21_extract_fixed_field( NEW.id, 'Type' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'Form' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'BLvl' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'Ctrl' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'ELvl' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'Audn' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'LitF' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'TMat' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'Desc' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'DtSt' ),
                biblio.marc21_extract_fixed_field( NEW.id, 'Lang' ),
                (   SELECT  v.value
                      FROM  biblio.marc21_physical_characteristics( NEW.id) p
                            JOIN config.marc21_physical_characteristic_subfield_map s ON (s.id = p.subfield)
                            JOIN config.marc21_physical_characteristic_value_map v ON (v.id = p.value)
                      WHERE p.ptype = 'v' AND s.subfield = 'e'    ),
                biblio.marc21_extract_fixed_field( NEW.id, 'Date1'),
                biblio.marc21_extract_fixed_field( NEW.id, 'Date2');

    -- On to URIs ...
    uris := oils_xpath('//*[@tag="856" and (@ind1="4" or @ind1="1") and (@ind2="0" or @ind2="1")]',NEW.marc);
    IF ARRAY_UPPER(uris,1) > 0 THEN
        FOR i IN 1 .. ARRAY_UPPER( uris ) LOOP
            -- First we pull infot out of the 856
            uri_xml     := uris[i];

            uri_href    := (oils_xpath('//*[@code="u"]/text()',uri_xml))[1];
            CONTINUE WHEN uri_href IS NULL;

            uri_label   := (oils_xpath('//*[@code="y"]/text()|//*[@code="3"]/text()|//*[@code="u"]/text()',uri_xml))[1];
            CONTINUE WHEN uri_label IS NULL;

            uri_owner   := (oils_xpath('//*[@code="9"]/text()|//*[@code="w"]/text()|//*[@code="n"]/text()',uri_xml))[1];
            CONTINUE WHEN uri_owner IS NULL;
    
            uri_use     := (oils_xpath('//*[@code="z"]/text()|//*[@code="2"]/text()|//*[@code="n"]/text()',uri_xml))[1];

            uri_owner := REGEXP_REPLACE(uri_owner, $re$^.*?\((\w+)\).*$$re$, E'\\1');
    
            SELECT id INTO uri_owner_id FROM actor.org_unit WHERE shortname = uri_owner;
            CONTINUE WHEN NOT FOUND;
    
            -- now we look for a matching uri
            SELECT id INTO uri_id FROM asset.uri WHERE label = uri_label AND href = uri_href AND use_restriction = uri_use AND active;
            IF NOT FOUND THEN -- create one
                INSERT INTO asset.uri (label, href, use_restriction) VALUES (uri_label, uri_href, uri_use);
                SELECT id INTO uri_id FROM asset.uri WHERE label = uri_label AND href = uri_href AND use_restriction = uri_use AND active;
            END IF;
    
            -- we need a call number to link through
            SELECT id INTO uri_cn_id FROM asset.call_number WHERE owning_lib = uri_owner_id AND record = NEW.id AND label = '##URI##' AND NOT deleted;
            IF NOT FOUND THEN
                INSERT INTO asset.call_number (owning_lib, record, create_date, edit_date, creator, editor, label)
                    VALUES (uri_owner_id, NEW.id, 'now', 'now', NEW.editor, NEW.editor, '##URI##');
                SELECT id INTO uri_cn_id FROM asset.call_number WHERE owning_lib = uri_owner_id AND record = NEW.id AND label = '##URI##' AND NOT deleted;
            END IF;
    
            -- now, link them if they're not already
            SELECT id INTO uri_map_id FROM asset.uri_call_number_map WHERE call_number = uri_cn_id AND uri = uri_id;
            IF NOT FOUND THEN
                INSERT INTO asset.uri_call_number_map (call_number, uri) VALUES (uri_cn_id, uri_id);
            END IF;
    
        END LOOP;
    END IF;

    -- And, finally, metarecord mapping!

    FOR tmp_mr IN SELECT  m.* FROM  metabib.metarecord m JOIN metabib.metarecord_source_map s ON (s.metarecord = m.id) WHERE s.source = NEW.id LOOP

        IF old_mr IS NULL AND NEW.fingerprint = tmp_mr.fingerprint THEN -- Find the first fingerprint-matching
            old_mr := tmp_mr.id;
        ELSE
            SELECT COUNT(*) INTO source_count FROM metabib.metarecord_source_map WHERE metarecord = tmp_mr.id;
            IF source_count = 0 THEN -- No other records
                deleted_mrs := ARRAY_APPEND(deleted_mrs, tmp_mr.id);
                DELETE FROM metabib.metarecord WHERE id = tmp_mr.id;
            END IF;
        END IF;

    END LOOP;

    IF old_mr IS NULL THEN -- we found no suitable, preexisting MR based on old source maps
        SELECT id INTO old_mr FROM metabib.metarecord WHERE fingerprint = NEW.fingerprint; -- is there one for our current fingerprint?
        IF old_mr IS NULL THEN -- nope, create one and grab its id
            INSERT INTO metabib.metarecord ( fingerprint, master_record ) VALUES ( NEW.fingerprint, NEW.id );
            SELECT id INTO old_mr FROM metabib.metarecord WHERE fingerprint = NEW.fingerprint;
        ELSE -- indeed there is. update it with a null cache and recalcualated master record
            UPDATE  metabib.metarecord
              SET   mods = NULL,
                    master_record = ( SELECT id FROM biblio.record_entry WHERE fingerprint = NEW.fingerprint ORDER BY quality DESC LIMIT 1)
              WHERE id = old_mr;
        END IF;
    ELSE -- there was one we already attached to, update its mods cache and master_record
        UPDATE  metabib.metarecord
          SET   mods = NULL,
                master_record = ( SELECT id FROM biblio.record_entry WHERE fingerprint = NEW.fingerprint ORDER BY quality DESC LIMIT 1)
          WHERE id = old_mr;
    END IF;

    INSERT INTO metabib.metarecord_source_map (metarecord, source) VALUES (old_mr, NEW.id); -- new source mapping

    UPDATE action.hold_request SET target = old_mr WHERE target IN ( SELECT explode_array(deleted_mrs) ) AND hold_type = 'M'; -- if we had to delete any MRs above, make sure their holds are moved

    RETURN NEW;

END;
$func$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION reporter.simple_rec_trigger () RETURNS TRIGGER AS $func$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM reporter.simple_rec_delete(NEW.id);
    ELSE
        PERFORM reporter.simple_rec_update(NEW.id);
    END IF;

    RETURN NEW;
END;
$func$ LANGUAGE PLPGSQL;

CREATE TRIGGER fingerprint_tgr BEFORE INSERT OR UPDATE ON biblio.record_entry FOR EACH ROW EXECUTE PROCEDURE biblio.fingerprint_trigger ('eng','BKS');
CREATE TRIGGER aaa_indexing_ingest_or_delete AFTER INSERT OR UPDATE ON biblio.record_entry FOR EACH ROW EXECUTE PROCEDURE biblio.indexing_ingest_or_delete ();
CREATE TRIGGER bbb_simple_rec_trigger AFTER INSERT OR UPDATE ON biblio.record_entry FOR EACH ROW EXECUTE PROCEDURE reporter.simple_rec_trigger ();

COMMIT;

-- Ingest triggers.  Not installed on all systems.  Delete outside the transaction
DROP TRIGGER zzz_update_materialized_simple_rec_delete_tgr ON biblio.record_entry;


