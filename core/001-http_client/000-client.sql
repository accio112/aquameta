/*******************************************************************************
 * WWW - client
 *
 * Created by Aquameta Labs, an open source company in Portland Oregon, USA.
 * Company: http://aquameta.com/
 * Project: http://blog.aquameta.com/
 ******************************************************************************/

begin;

create language plpythonu;
create schema http_client;
set search_path=http_client;



/*******************************************************************************
*
*
* UTILS
* General purpose http client utilities.
*
*
*******************************************************************************/


/*******************************************************************************
* urlencode
* via http://stackoverflow.com/questions/10318014/javascript-encodeuri-like-function-in-postgresql
*******************************************************************************/
CREATE OR REPLACE FUNCTION http_client.urlencode(in_str text, OUT _result text)
    STRICT IMMUTABLE AS $urlencode$
DECLARE
    _i      int4;
    _temp   varchar;
    _ascii  int4;
BEGIN
    _result = '';
    FOR _i IN 1 .. length(in_str) LOOP
        _temp := substr(in_str, _i, 1);
        IF _temp ~ '[0-9a-zA-Z:/@._?#-]+' THEN
            _result := _result || _temp;
        ELSE
            _ascii := ascii(_temp);
            IF _ascii > x'07ff'::int4 THEN
                RAISE EXCEPTION 'Won''t deal with 3 (or more) byte sequences.';
            END IF;
            IF _ascii <= x'07f'::int4 THEN
                _temp := '%'||to_hex(_ascii);
            ELSE
                _temp := '%'||to_hex((_ascii & x'03f'::int4)+x'80'::int4);
                _ascii := _ascii >> 6;
                _temp := '%'||to_hex((_ascii & x'01f'::int4)+x'c0'::int4)
                            ||_temp;
            END IF;
            _result := _result || upper(_temp);
        END IF;
    END LOOP;
    RETURN ;
END;
$urlencode$ LANGUAGE plpgsql;



/*******************************************************************************
* array_to_querystring(args, vals)
* converts an array of args and an array of values to a query_string suitbale for a URL
*******************************************************************************/
create or replace function http_client.array_to_querystring(args text[], vals text[], out querystring text) as $$
begin
    querystring := '';

    raise notice 'qs: %', querystring;
    for i in 1..array_length(args,1) loop
        querystring := querystring
            || http_client.urlencode(args[i])
            -- || args[i]
            || '='
            || http_client.urlencode(vals[i])
            -- || vals[i]
            || '&';
        raise notice 'qs: %', querystring;
    end loop;

end;
$$ language plpgsql;



/*******************************************************************************
*
*
* HTTP CLIENT
* Performs GET, POST, DELETE, PATCH operations over HTTP using python's liburl2
*
*
*******************************************************************************/


/*******************************************************************************
* http_get
*******************************************************************************/
create or replace function http_client.http_get (url text) returns text
as $$

import urllib2
import plpy

plpy.notice('************ http_get('+url+')')
req = urllib2.Request(url)
response = urllib2.urlopen(req)
raw_response = response.read()
return raw_response

$$ language plpythonu;

/*******************************************************************************
* http_post
*******************************************************************************/
create or replace function http_client.http_post(url text, data text)
returns text
as $$
import urllib2

req = urllib2.Request(url, data)
response = urllib2.urlopen(req)
raw_response = response.read()
return raw_response

$$ language plpythonu;



/*******************************************************************************
* http_delete
*******************************************************************************/
create or replace function http_client.http_delete(url text)
returns text
as $$
import urllib2

req = urllib2.Request(url)
req.get_method = lambda: 'DELETE'
response = urllib2.urlopen(req)
raw_response = response.read()
return raw_response

$$ language plpythonu;



/*******************************************************************************
* http_patch
*******************************************************************************/
create or replace function http_client.http_patch(url text, data text)
returns text
as $$
import urllib2

req = urllib2.Request(url, data)
req.get_method = lambda: 'PATCH'
response = urllib2.urlopen(req)
raw_response = response.read()
return raw_response

$$ language plpythonu;

commit;
