-- Which stage "Decide now" is on, so the room can show the thinking as it happens (2026-10-19).
-- Set by the server's decide worker only; cleared when the analysis is written or the run fails.
alter table rooms add column decide_stage text
  check (decide_stage is null or decide_stage in ('reading', 'sensemaking', 'facts', 'math', 'judging', 'writing'));
