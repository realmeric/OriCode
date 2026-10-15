-- A made-up conversation in the store Cursor keeps a chat or an ACP session in: blobs by hash,
-- each message as the AI SDK's JSON, and a root blob listing the messages in order as protobuf's
-- field 1, beside fields of something else. The meta row names the root, in hex-encoded JSON.
create table blobs (id text primary key, data blob);
create table meta (key text primary key, value text);

insert into blobs values
  ('1111111111111111111111111111111111111111111111111111111111111111', cast('{"role":"system","content":"You are an agent."}' as blob)),
  ('2222222222222222222222222222222222222222222222222222222222222222', cast('{"role":"user","content":"<user_info>OS: darwin</user_info>"}' as blob)),
  ('3333333333333333333333333333333333333333333333333333333333333333', cast('{"role":"user","content":[{"type":"text","text":"<timestamp>Monday</timestamp>\n<user_query>\nWhat does make test run?\n</user_query>"}]}' as blob)),
  ('4444444444444444444444444444444444444444444444444444444444444444', cast('{"role":"assistant","content":[{"type":"redacted-reasoning","data":"zz"},{"type":"text","text":"Reading the Makefile."},{"type":"tool-call","toolCallId":"call-1","toolName":"Read","args":{"path":"/w/p/Makefile"}}]}' as blob)),
  ('5555555555555555555555555555555555555555555555555555555555555555', cast('{"role":"tool","content":[{"type":"tool-result","toolCallId":"call-1","toolName":"Read","result":"test:\n\tnode --test"}]}' as blob)),
  ('6666666666666666666666666666666666666666666666666666666666666666', cast('{"role":"assistant","content":[{"type":"text","text":"It runs node --test."}]}' as blob)),
  -- Concatenation makes text, so the root is cast back to the blob it is.
  ('ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', cast(
    X'0a201111111111111111111111111111111111111111111111111111111111111111'
    || X'0a202222222222222222222222222222222222222222222222222222222222222222'
    || X'0a203333333333333333333333333333333333333333333333333333333333333333'
    || X'0a204444444444444444444444444444444444444444444444444444444444444444'
    || X'0a205555555555555555555555555555555555555555555555555555555555555555'
    || X'1203616263'
    || X'0a206666666666666666666666666666666666666666666666666666666666666666'
    || X'd00101' as blob));

insert into meta values ('0', lower(hex('{"agentId":"chat-1","latestRootBlobId":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","name":"Make test"}')));
