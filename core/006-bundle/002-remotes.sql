/*******************************************************************************
 * Bundle Remotes
 *
 * Created by Aquameta Labs, an open source company in Portland Oregon, USA.
 * Company: http://aquameta.com/
 * Project: http://blog.aquameta.com/
 ******************************************************************************/

begin;

set search_path=bundle;

/*******************************************************************************
*
*
* BUNDLE REMOTES
*
*
*******************************************************************************/

/*******************************************************************************
* bundle.has_bundle
* checks a remote to see if it also has a bundle with the same id installed
*******************************************************************************/

create or replace function bundle.remote_has_bundle(in _remote_id uuid, out has_bundle boolean)
as $$
declare
    local_bundle_id uuid;
    remote_endpoint_id uuid;
begin
    -- look up endpoint_id
    select into remote_endpoint_id e.id from endpoint.remote_endpoint e join bundle.remote r on r.endpoint_id = e.id where r.id = _remote_id;
    select into local_bundle_id r.bundle_id from endpoint.remote_endpoint e join bundle.remote r on r.endpoint_id = e.id where r.id = _remote_id;

    -- 
    select into has_bundle (count(*) = 1)::boolean from (
        select 
            (json_array_elements((rc.response_text::json)->'result')->'row'->>'id') as id
            from endpoint.client_rows_select(
                    remote_endpoint_id,
                    meta.relation_id('bundle','bundle'),
                    ARRAY['id'],
                    ARRAY[local_bundle_id::text]
            ) rc
    ) has;
end;
$$ language plpgsql;





/*******************************************************************************
* bundle.remote_compare_commits
* diffs the set of local commits with the set of remote commits
*******************************************************************************/

create or replace function bundle.remote_compare_commits(in _remote_id uuid)
returns table(local_commit_id uuid, remote_commit_id uuid)
as $$
declare
    local_bundle_id uuid;
    remote_endpoint_id uuid;
begin
    select into local_bundle_id bundle_id from bundle.remote r where r.id = _remote_id;
    select into remote_endpoint_id e.id from endpoint.remote_endpoint e join bundle.remote r on r.endpoint_id = e.id where r.id = _remote_id;

    raise notice 'compare: % % %', _remote_id, local_bundle_id, remote_endpoint_id;

    return query
        with remote_commit as (
            select 
                (json_array_elements((rc.response_text::json)->'result')->'row'->>'id')::uuid as id
            from 
                endpoint.client_rows_select(
                    remote_endpoint_id,
                    meta.relation_id('bundle','commit'),
                    ARRAY['bundle_id'],
                    ARRAY[local_bundle_id::text]
            ) rc
        )
        select lc.id, rc.id
        from remote_commit rc
        full outer join bundle.commit lc on lc.id = rc.id
        where lc.bundle_id = local_bundle_id or lc.bundle_id is null;
end;
$$ language plpgsql;







/*******************************************************************************
* bundle.construct_bundle_diff
* fills a temporary table with the commits specified, but only including NEW blobs
*******************************************************************************/

create or replace function bundle.construct_bundle_diff(bundle_id uuid, new_commits uuid[], temp_table_name text)
returns setof endpoint.join_graph_row as $$
declare
    new_commits_str text;
begin
    select into new_commits_str string_agg(q,',') from (
    select quote_literal(unnest(new_commits)) q) as quoted;
    raise notice '######## CONSTRUCTING BUNDLE DIFF FOR COMMITS %', new_commits_str;

    perform endpoint.construct_join_graph(
            temp_table_name,
            ('{ "schema_name": "bundle", "relation_name": "bundle", "label": "b", "local_id": "id", "where_clause": "b.id = ''' || bundle_id::text || '''", "position": 1, "exclude": true }')::json,
            ('[
                {"schema_name": "bundle", "relation_name": "commit",           "label": "c",   "local_id": "bundle_id",     "related_label": "b",   "related_field": "id",         "position": 6, "where_clause": "c.id in (' || new_commits_str || ')"},
                {"schema_name": "bundle", "relation_name": "rowset",           "label": "r",   "local_id": "id",            "related_label": "c",   "related_field": "rowset_id",  "position": 2},
                {"schema_name": "bundle", "relation_name": "rowset_row",       "label": "rr",  "local_id": "rowset_id",     "related_label": "r",   "related_field": "id",         "position": 3},
                {"schema_name": "bundle", "relation_name": "rowset_row_field", "label": "rrf", "local_id": "rowset_row_id", "related_label": "rr",  "related_field": "id",         "position": 5},
                {"schema_name": "bundle", "relation_name": "blob",             "label": "blb", "local_id": "hash",          "related_label": "rrf", "related_field": "value_hash", "position": 4}
             ]')::json
        );

    return query execute format ('select row_id, row::jsonb from %I order by position', quote_ident(temp_table_name));

end;
$$ language plpgsql;




/*******************************************************************************
* bundle.push
* transfer to a remote repository any local commits not present in the remote
*******************************************************************************/

create or replace function bundle.remote_push(in remote_id uuid)
returns void -- table(_row_id meta.row_id)
as $$
declare
    ct integer;
    new_commits uuid[];
    bundle_id uuid;
    result json;
    result2 json;
    r endpoint.join_graph_row;
begin
    raise notice '################################### PUSH ##########################';
    select into bundle_id be.bundle_id from bundle.remote be where be.id = remote_id;

    -- get the array of new remote commits
    select into new_commits array_agg(local_commit_id)
        from bundle.remote_compare_commits(remote_id)
        where remote_commit_id is null;

    raise notice 'NEW COMMITS: %', new_commits::text;

    perform bundle.construct_bundle_diff(bundle_id, new_commits, 'bundle_push_1234');


    -- build json object
    select into result2 array_to_json(array_agg(('{ "row": ' || row_to_json(tmp)::text || ', "selector": "hi mom"}')::json)) from bundle_push_1234 tmp;
    result := ('{"columns":[{"name":"row_id","type":"row_id"},{"name":"row","type":"json"}], "result": ' || result2 || '}')::json;

    raise notice 'PUUUUUUUUUSH result: %', result::text;

    -- http://hashrocket.com/blog/posts/faster-json-generation-with-postgresql
    perform http_client.endpoint_rows_insert (remote_id, result);
    -- from (select * from bundle_push_1234 order by position) as b;

    drop table _bundle_push_1234;
end;
$$ language plpgsql;


/*
{"columns":[{"name":"row_id","type":"text"},{"name":"row","type":"jsonb"}],"result":[{ "row": {"row_id":"(\"(\"\"(\"\"\"\"(bundle)\"\"\"\",rowset)\"\",id)\",58887a7f-3428-401c-a24e-5eaa0f5c378f)","row":{"id": "58887a7f-3428-401c-a24e-5eaa0f5c378f"}}, "selector": "bundle/function/construct_bundle_diff/rows/?" },{ "row": {"row_id":"(\"(\"\"(\"\"\"\"(bundle)\"\"\"\",rowset)\"\",id)\",9e220a23-fdeb-4b12-97f3-8b61a7b39d89)","row":{"id": "9e220a23-fdeb-4b12-97f3-8b61a7b39d89"}}, "selector": "bundle/function/construct_bundle_diff/rows/?" },{ "row": {"row_id":"(\"(\"\"(\"\"\"\"(bundle)\"\"\"\",rowset)\"\",id)\",233d73e2-6b04-4697-83af-1c3da4fb091e)","row":{"id": "233d73e2-6b04-4697-83af-1c3da4fb091e"}}, "selector": "bundle/function/construct_bundle_diff/rows/?" },{ "row": {"row_id":"(\"(\"\"(\"\"\"\"(bundle)\"\"\"\",rowset_row)\"\",rowset_id)\",58887a7f-3428-401c-a24e-5eaa0f5c378f)","row":{"id": "d619218d-77ff-4951-8ccf-7cbf2ace20c0", "row_id": {"pk_value": "17a50da2-eba6-4295-8875-a6936ca4109e", "pk_column_id": {"name": "id", "relation_id": {"name": "widget", "schema_id": {"name": "widget"}}}}, "rowset_id": "58887a7f-3428-401c-a24e-5eaa0f5c378f"}}, "selector": "bundle/function/construct_bundle_diff/rows/?" },{ "row": {"row_id":"(\"(\"\"(\"\"\"\"(bundle)\"\"\"\",rowset_row)\"\",rowset_id)\",58887a7f-3428-401c-a24e-5eaa0f5c378f)" |]}
*/



/*******************************************************************************
* bundle.fetch
* download from remote repository any commits not present in the local repository
*******************************************************************************/

create or replace function bundle.remote_fetch(in remote_id uuid)
returns void -- table(_row_id meta.row_id)
as $$
declare
    ct integer;
    bundle_id uuid;
    new_commits uuid[];
    json_results text;
begin
    raise notice '################################### FETCH ##########################';
    select into bundle_id be.bundle_id from bundle.remote be where be.id = remote_id;

    -- get the array of new remote commits
    select into new_commits array_agg(remote_commit_id)
        from bundle.remote_compare_commits(remote_id)
        where local_commit_id is null;

    raise notice 'NEW COMMITS: %', new_commits::text;

    select into json_results http_client.endpoint_rows_select_function(
        remote_id,
        meta.function_id('bundle','construct_bundle_diff', ARRAY['bundle_id','new_commits','temp_table_name']),
        ARRAY[bundle_id::text, new_commits::text, 'bundle_diff_1234'::text]
    );

    raise notice '############################ JSON %', json_results;

    -- create a join_graph on the remote via the construct_bundle_diff function
    select into json_results result::json->'result' from http_client.endpoint_rows_select_function(
        remote_id,
        meta.function_id('bundle','construct_bundle_diff', ARRAY['bundle_id','new_commits','temp_table_name']),
        ARRAY[bundle_id::text, new_commits::text, 'bundle_diff_1234'::text]
    );
    raise notice '################# RESULTS: %', json_results;
    perform www.rows_insert(json_results::json);

    /*
    -- http://hashrocket.com/blog/posts/faster-json-generation-with-postgresql
    perform http_client.endpoint_rows_insert (
        remote_id,
        array_to_json(
            array_agg(
                row_to_json(b)
            )
        )
    )
    from (select * from _bundle_push_temp order by position) as b;

    drop table _bundle_push_temp;
    */
end;
$$ language plpgsql;


commit;
