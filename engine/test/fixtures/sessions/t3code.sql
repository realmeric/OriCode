-- A made-up T3 Code store, with only the columns an import reads: two projects, threads on
-- Cursor and on Claude underneath, one on an agent OriCode doesn't run, one deleted, and the
-- messages T3 Code kept of them.
create table projection_projects (project_id text primary key, title text, workspace_root text, deleted_at text);
create table projection_threads (thread_id text primary key, project_id text, title text, branch text, worktree_path text, updated_at text, deleted_at text);
create table provider_session_runtime (thread_id text primary key, provider_name text, resume_cursor_json text, runtime_payload_json text);
create table projection_thread_messages (message_id text primary key, thread_id text, role text, text text, created_at text);

insert into projection_projects values ('p', 'p', '/w/p', null), ('q', 'q', '/w/q', null);

insert into projection_threads values
  ('t-cursor', 'p', 'Make test, explained', 'main', null, '2026-09-20T10:00:00.000Z', null),
  ('t-claude', 'p', 'Before the move', null, null, '2026-09-19T10:00:00.000Z', null),
  ('t-grok', 'p', 'On Grok', null, null, '2026-09-18T10:00:00.000Z', null),
  ('t-gone', 'p', 'Deleted', null, null, '2026-09-21T10:00:00.000Z', '2026-09-22T10:00:00.000Z'),
  ('t-other', 'q', 'Another project', null, null, '2026-09-21T10:00:00.000Z', null);

insert into provider_session_runtime values
  ('t-cursor', 'cursor', '{"schemaVersion":1,"sessionId":"acp-1"}', '{"cwd":"/w/p"}'),
  ('t-claude', 'claudeAgent', '{"threadId":"t-claude","resume":"9f0e0c55-0000-4000-8000-000000000001","turnCount":1}', '{"cwd":"/w/old"}'),
  ('t-grok', 'grok', '{"sessionId":"g-1"}', '{"cwd":"/w/p"}');

insert into projection_thread_messages values
  ('m1', 't-claude', 'user', 'Where does the store live?', '2026-09-19T10:00:00.000Z'),
  ('m2', 't-claude', 'assistant', 'In Application Support.', '2026-09-19T10:00:01.000Z'),
  ('m3', 't-claude', 'assistant', 'Under OriCode.', '2026-09-19T10:00:02.000Z'),
  ('m4', 't-cursor', 'user', 'What does make test run?', '2026-09-20T10:00:00.000Z');
