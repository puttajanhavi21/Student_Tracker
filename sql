-- =============================================================================
-- STUDENT TRACKER APPLICATION - POSTGRESQL DATABASE SCHEMA
-- Version: 1.0 | Standard: 3NF Normalised | Convention: snake_case
-- Architect: Senior DB Design | Target: PostgreSQL 14+
-- =============================================================================

-- =============================================================================
-- SECTION 0: EXTENSIONS & CUSTOM TYPES
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- For gen_random_uuid() if needed
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- For fuzzy text search on notes/tasks

-- ENUM types for constrained categorical fields
CREATE TYPE task_status      AS ENUM ('pending', 'in_progress', 'completed', 'cancelled');
CREATE TYPE task_priority    AS ENUM ('low', 'medium', 'high', 'critical');
CREATE TYPE task_category    AS ENUM ('academic', 'personal', 'fitness', 'event', 'project', 'other');
CREATE TYPE mood_type        AS ENUM ('very_sad', 'sad', 'neutral', 'happy', 'very_happy');
CREATE TYPE grade_type       AS ENUM ('S', 'A', 'B', 'C', 'D', 'E', 'F', 'I', 'W');
CREATE TYPE event_type       AS ENUM ('lecture', 'exam', 'assignment_due', 'personal', 'club', 'other');
CREATE TYPE reminder_status  AS ENUM ('pending', 'sent', 'dismissed');
CREATE TYPE export_format    AS ENUM ('pdf', 'excel', 'csv');
CREATE TYPE notification_type AS ENUM ('reminder', 'grade_update', 'task_due', 'event', 'system');

-- =============================================================================
-- SECTION 1: CORE USER & AUTHENTICATION
-- =============================================================================

-- Users: One row per registered student. MAHE ID is globally unique.
CREATE TABLE users (
    user_id         SERIAL          PRIMARY KEY,
    mahe_id         VARCHAR(20)     NOT NULL UNIQUE,           -- e.g. "230905001"
    full_name       VARCHAR(120)    NOT NULL,
    email           VARCHAR(200)    NOT NULL UNIQUE,
    password_hash   VARCHAR(255)    NOT NULL,                  -- bcrypt/argon2 hash; NEVER plaintext
    avatar_url      TEXT,
    branch          VARCHAR(80),
    semester        SMALLINT        CHECK (semester BETWEEN 1 AND 12),
    academic_year   SMALLINT        CHECK (academic_year BETWEEN 2000 AND 2100),
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    last_login_at   TIMESTAMP WITH TIME ZONE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Session management (supports multiple devices / JWT refresh tokens)
CREATE TABLE user_sessions (
    session_id      SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    refresh_token   VARCHAR(512)    NOT NULL UNIQUE,
    device_info     TEXT,
    ip_address      INET,
    expires_at      TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- User preferences (one-to-one with users; keeps users table lean)
CREATE TABLE user_preferences (
    user_id             INT         PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    theme               VARCHAR(20) NOT NULL DEFAULT 'light' CHECK (theme IN ('light', 'dark', 'system')),
    timezone            VARCHAR(60) NOT NULL DEFAULT 'Asia/Kolkata',
    notifications_email BOOLEAN     NOT NULL DEFAULT TRUE,
    notifications_push  BOOLEAN     NOT NULL DEFAULT TRUE,
    weekly_report       BOOLEAN     NOT NULL DEFAULT FALSE,
    updated_at          TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- SECTION 2: ACADEMIC — COURSES & CREDITS
-- =============================================================================

-- Master course catalogue (institution-level; not per-user)
CREATE TABLE courses (
    course_id       SERIAL          PRIMARY KEY,
    course_code     VARCHAR(20)     NOT NULL UNIQUE,           -- e.g. "CSE301"
    course_name     VARCHAR(150)    NOT NULL,
    credits         NUMERIC(3,1)    NOT NULL CHECK (credits > 0),
    department      VARCHAR(80),
    description     TEXT,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Enrolment: links users to courses for a specific semester/year
-- Supports history (same course retaken different year)
CREATE TABLE enrolments (
    enrolment_id    SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    course_id       INT             NOT NULL REFERENCES courses(course_id) ON DELETE RESTRICT,
    semester        SMALLINT        NOT NULL CHECK (semester BETWEEN 1 AND 12),
    academic_year   SMALLINT        NOT NULL CHECK (academic_year BETWEEN 2000 AND 2100),
    final_grade     grade_type,
    grade_points    NUMERIC(3,2)    CHECK (grade_points BETWEEN 0 AND 10),
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
    enrolled_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, course_id, semester, academic_year)       -- prevents duplicate enrolment
);

-- Assignments per course-enrolment (not per user directly — avoids redundancy)
CREATE TABLE assignments (
    assignment_id   SERIAL          PRIMARY KEY,
    enrolment_id    INT             NOT NULL REFERENCES enrolments(enrolment_id) ON DELETE CASCADE,
    title           VARCHAR(200)    NOT NULL,
    description     TEXT,
    max_marks       NUMERIC(6,2)    NOT NULL CHECK (max_marks > 0),
    obtained_marks  NUMERIC(6,2)    CHECK (obtained_marks >= 0),
    weightage       NUMERIC(5,2)    CHECK (weightage BETWEEN 0 AND 100),  -- % of total grade
    due_date        DATE,
    submitted_at    TIMESTAMP WITH TIME ZONE,
    is_submitted    BOOLEAN         NOT NULL DEFAULT FALSE,
    feedback        TEXT,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CHECK (obtained_marks IS NULL OR obtained_marks <= max_marks)
);

-- Grade components breakdown (CIE, SEE, quiz, lab, etc.)
CREATE TABLE grade_components (
    component_id    SERIAL          PRIMARY KEY,
    enrolment_id    INT             NOT NULL REFERENCES enrolments(enrolment_id) ON DELETE CASCADE,
    component_name  VARCHAR(80)     NOT NULL,                  -- "CIE-1", "Lab", "SEE"
    max_marks       NUMERIC(6,2)    NOT NULL CHECK (max_marks > 0),
    obtained_marks  NUMERIC(6,2)    CHECK (obtained_marks >= 0),
    weightage       NUMERIC(5,2)    CHECK (weightage BETWEEN 0 AND 100),
    conducted_on    DATE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CHECK (obtained_marks IS NULL OR obtained_marks <= max_marks)
);

-- Attendance tracking per enrolment
CREATE TABLE attendance_records (
    record_id       SERIAL          PRIMARY KEY,
    enrolment_id    INT             NOT NULL REFERENCES enrolments(enrolment_id) ON DELETE CASCADE,
    class_date      DATE            NOT NULL,
    is_present      BOOLEAN         NOT NULL,
    remarks         VARCHAR(200),
    UNIQUE (enrolment_id, class_date)
);

-- =============================================================================
-- SECTION 3: TASK / TO-DO SYSTEM
-- =============================================================================

-- Task categories are dynamic (user-defined labels) + system auto-tags via ENUM
CREATE TABLE task_labels (
    label_id        SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    label_name      VARCHAR(60)     NOT NULL,
    colour_hex      CHAR(7)         CHECK (colour_hex ~ '^#[0-9A-Fa-f]{6}$'),
    UNIQUE (user_id, label_name)
);

CREATE TABLE tasks (
    task_id         SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    title           VARCHAR(300)    NOT NULL,
    description     TEXT,
    status          task_status     NOT NULL DEFAULT 'pending',
    priority        task_priority   NOT NULL DEFAULT 'medium',
    category        task_category   NOT NULL DEFAULT 'personal',   -- auto-classifiable
    due_date        TIMESTAMP WITH TIME ZONE,
    completed_at    TIMESTAMP WITH TIME ZONE,
    -- Optional link to academic context
    enrolment_id    INT             REFERENCES enrolments(enrolment_id) ON DELETE SET NULL,
    assignment_id   INT             REFERENCES assignments(assignment_id) ON DELETE SET NULL,
    is_recurring    BOOLEAN         NOT NULL DEFAULT FALSE,
    recurrence_rule VARCHAR(100),                                  -- iCal RRULE string
    parent_task_id  INT             REFERENCES tasks(task_id) ON DELETE CASCADE,  -- subtasks
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Many-to-many: tasks <-> labels
CREATE TABLE task_label_map (
    task_id         INT             NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
    label_id        INT             NOT NULL REFERENCES task_labels(label_id) ON DELETE CASCADE,
    PRIMARY KEY (task_id, label_id)
);

-- =============================================================================
-- SECTION 4: EVENTS & CALENDAR
-- =============================================================================

CREATE TABLE events (
    event_id        SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    title           VARCHAR(300)    NOT NULL,
    description     TEXT,
    event_type      event_type      NOT NULL DEFAULT 'personal',
    location        VARCHAR(200),
    starts_at       TIMESTAMP WITH TIME ZONE NOT NULL,
    ends_at         TIMESTAMP WITH TIME ZONE,
    is_all_day      BOOLEAN         NOT NULL DEFAULT FALSE,
    -- Optional academic link
    enrolment_id    INT             REFERENCES enrolments(enrolment_id) ON DELETE SET NULL,
    is_recurring    BOOLEAN         NOT NULL DEFAULT FALSE,
    recurrence_rule VARCHAR(100),
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CHECK (ends_at IS NULL OR ends_at >= starts_at)
);

CREATE TABLE reminders (
    reminder_id     SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    -- Polymorphic target: exactly one of the following should be non-null
    event_id        INT             REFERENCES events(event_id) ON DELETE CASCADE,
    task_id         INT             REFERENCES tasks(task_id) ON DELETE CASCADE,
    assignment_id   INT             REFERENCES assignments(assignment_id) ON DELETE CASCADE,
    remind_at       TIMESTAMP WITH TIME ZONE NOT NULL,
    status          reminder_status NOT NULL DEFAULT 'pending',
    message         VARCHAR(500),
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    -- Enforce polymorphic integrity: exactly one target
    CHECK (
        (event_id IS NOT NULL)::INT +
        (task_id IS NOT NULL)::INT +
        (assignment_id IS NOT NULL)::INT = 1
    )
);

-- =============================================================================
-- SECTION 5: NOTES & PERSONAL PROJECTS
-- =============================================================================

CREATE TABLE note_folders (
    folder_id       SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    folder_name     VARCHAR(100)    NOT NULL,
    parent_folder_id INT            REFERENCES note_folders(folder_id) ON DELETE CASCADE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, folder_name, parent_folder_id)
);

CREATE TABLE notes (
    note_id         SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    folder_id       INT             REFERENCES note_folders(folder_id) ON DELETE SET NULL,
    enrolment_id    INT             REFERENCES enrolments(enrolment_id) ON DELETE SET NULL,
    title           VARCHAR(300)    NOT NULL,
    content         TEXT,
    is_pinned       BOOLEAN         NOT NULL DEFAULT FALSE,
    is_archived     BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Note tags (separate from task labels — different domain)
CREATE TABLE note_tags (
    tag_id          SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    tag_name        VARCHAR(60)     NOT NULL,
    UNIQUE (user_id, tag_name)
);

CREATE TABLE note_tag_map (
    note_id         INT             NOT NULL REFERENCES notes(note_id) ON DELETE CASCADE,
    tag_id          INT             NOT NULL REFERENCES note_tags(tag_id) ON DELETE CASCADE,
    PRIMARY KEY (note_id, tag_id)
);

-- Personal projects (distinct from academic; portfolio / side projects)
CREATE TABLE projects (
    project_id      SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    title           VARCHAR(200)    NOT NULL,
    description     TEXT,
    tech_stack      TEXT[],                                    -- PostgreSQL array; e.g. '{React,Node,Postgres}'
    repo_url        TEXT,
    demo_url        TEXT,
    status          VARCHAR(40)     NOT NULL DEFAULT 'planning'
                    CHECK (status IN ('planning','active','on_hold','completed','abandoned')),
    start_date      DATE,
    end_date        DATE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE TABLE project_milestones (
    milestone_id    SERIAL          PRIMARY KEY,
    project_id      INT             NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    title           VARCHAR(200)    NOT NULL,
    due_date        DATE,
    is_completed    BOOLEAN         NOT NULL DEFAULT FALSE,
    completed_at    TIMESTAMP WITH TIME ZONE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- SECTION 6: FITNESS TRACKING
-- =============================================================================

-- Daily fitness log (one row per user per day — avoids aggregation confusion)
CREATE TABLE fitness_daily_logs (
    log_id          SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    log_date        DATE            NOT NULL,
    steps           INT             CHECK (steps >= 0),
    calories_burned NUMERIC(8,2)    CHECK (calories_burned >= 0),
    calories_intake NUMERIC(8,2)    CHECK (calories_intake >= 0),
    active_minutes  SMALLINT        CHECK (active_minutes >= 0),
    water_ml        INT             CHECK (water_ml >= 0),
    sleep_hours     NUMERIC(4,2)    CHECK (sleep_hours BETWEEN 0 AND 24),
    weight_kg       NUMERIC(5,2)    CHECK (weight_kg > 0),
    notes           TEXT,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, log_date)
);

-- Fitness goals (current target; history tracked via created_at)
CREATE TABLE fitness_goals (
    goal_id         SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    goal_type       VARCHAR(40)     NOT NULL CHECK (goal_type IN ('steps','calories','water','sleep','weight','active_minutes')),
    target_value    NUMERIC(10,2)   NOT NULL CHECK (target_value > 0),
    effective_from  DATE            NOT NULL DEFAULT CURRENT_DATE,
    effective_to    DATE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

-- Workout sessions (granular; separate from daily logs)
CREATE TABLE workout_sessions (
    session_id      SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    workout_type    VARCHAR(80)     NOT NULL,                  -- "Running", "Gym", "Yoga"
    duration_mins   SMALLINT        NOT NULL CHECK (duration_mins > 0),
    calories_burned NUMERIC(7,2)    CHECK (calories_burned >= 0),
    distance_km     NUMERIC(7,3)    CHECK (distance_km >= 0),
    notes           TEXT,
    performed_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- SECTION 7: MENTAL HEALTH TRACKING
-- =============================================================================

CREATE TABLE mood_logs (
    mood_id         SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    mood            mood_type       NOT NULL,
    energy_level    SMALLINT        CHECK (energy_level BETWEEN 1 AND 10),
    stress_level    SMALLINT        CHECK (stress_level BETWEEN 1 AND 10),
    notes           TEXT,                                      -- Optional; privacy-sensitive
    logged_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    -- Prevent multiple logs within the same hour (soft dedup)
    UNIQUE (user_id, date_trunc('hour', logged_at))
);

-- Gratitude / journal entries (separate from mood — distinct purpose)
CREATE TABLE journal_entries (
    entry_id        SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    content         TEXT            NOT NULL,
    is_private      BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- SECTION 8: NOTIFICATIONS
-- =============================================================================

CREATE TABLE notifications (
    notification_id SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    type            notification_type NOT NULL,
    title           VARCHAR(200)    NOT NULL,
    body            TEXT,
    is_read         BOOLEAN         NOT NULL DEFAULT FALSE,
    read_at         TIMESTAMP WITH TIME ZONE,
    -- Polymorphic source reference (optional)
    source_table    VARCHAR(60),                               -- e.g. "tasks", "events"
    source_id       INT,                                       -- PK of source row
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- SECTION 9: DATA EXPORT AUDIT
-- =============================================================================

CREATE TABLE export_requests (
    export_id       SERIAL          PRIMARY KEY,
    user_id         INT             NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    format          export_format   NOT NULL,
    scope           VARCHAR(80)     NOT NULL,                  -- "all", "academic", "fitness", etc.
    requested_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMP WITH TIME ZONE,
    file_url        TEXT,                                      -- S3/storage URL after generation
    status          VARCHAR(20)     NOT NULL DEFAULT 'queued'
                    CHECK (status IN ('queued','processing','completed','failed'))
);

-- =============================================================================
-- SECTION 10: INDEXES FOR PERFORMANCE
-- =============================================================================

-- Users
CREATE UNIQUE INDEX idx_users_mahe_id    ON users(mahe_id);
CREATE UNIQUE INDEX idx_users_email      ON users(email);
CREATE INDEX        idx_users_is_active  ON users(is_active) WHERE is_active = TRUE;

-- Sessions
CREATE INDEX idx_sessions_user_id        ON user_sessions(user_id);
CREATE INDEX idx_sessions_expires_at     ON user_sessions(expires_at);

-- Enrolments
CREATE INDEX idx_enrolments_user_id      ON enrolments(user_id);
CREATE INDEX idx_enrolments_course_id    ON enrolments(course_id);
CREATE INDEX idx_enrolments_year_sem     ON enrolments(academic_year, semester);

-- Assignments
CREATE INDEX idx_assignments_enrolment   ON assignments(enrolment_id);
CREATE INDEX idx_assignments_due_date    ON assignments(due_date);

-- Tasks (high-frequency queries)
CREATE INDEX idx_tasks_user_id           ON tasks(user_id);
CREATE INDEX idx_tasks_status            ON tasks(status);
CREATE INDEX idx_tasks_due_date          ON tasks(due_date);
CREATE INDEX idx_tasks_user_status       ON tasks(user_id, status);           -- composite for dashboard
CREATE INDEX idx_tasks_category          ON tasks(category);

-- Events
CREATE INDEX idx_events_user_id          ON events(user_id);
CREATE INDEX idx_events_starts_at        ON events(starts_at);
CREATE INDEX idx_events_user_starts      ON events(user_id, starts_at);       -- upcoming events query

-- Reminders
CREATE INDEX idx_reminders_user_id       ON reminders(user_id);
CREATE INDEX idx_reminders_remind_at     ON reminders(remind_at);
CREATE INDEX idx_reminders_status        ON reminders(status) WHERE status = 'pending';

-- Notes (full-text search via pg_trgm)
CREATE INDEX idx_notes_user_id           ON notes(user_id);
CREATE INDEX idx_notes_folder_id         ON notes(folder_id);
CREATE INDEX idx_notes_title_trgm        ON notes USING GIN (title gin_trgm_ops);
CREATE INDEX idx_notes_content_trgm      ON notes USING GIN (content gin_trgm_ops);

-- Fitness
CREATE INDEX idx_fitness_user_date       ON fitness_daily_logs(user_id, log_date DESC);
CREATE INDEX idx_workout_user_performed  ON workout_sessions(user_id, performed_at DESC);

-- Mood
CREATE INDEX idx_mood_user_logged        ON mood_logs(user_id, logged_at DESC);

-- Notifications
CREATE INDEX idx_notif_user_unread       ON notifications(user_id, is_read) WHERE is_read = FALSE;
CREATE INDEX idx_notif_user_created      ON notifications(user_id, created_at DESC);

-- =============================================================================
-- SECTION 11: SAMPLE INSERT DATA
-- =============================================================================

-- Users
INSERT INTO users (mahe_id, full_name, email, password_hash, branch, semester, academic_year) VALUES
('230905001', 'Arjun Sharma',    'arjun.sharma@learner.manipal.edu',  '$2b$12$xyz...hash1', 'Computer Science', 5, 2024),
('230905002', 'Priya Nair',      'priya.nair@learner.manipal.edu',    '$2b$12$xyz...hash2', 'Information Technology', 5, 2024),
('230905003', 'Rohan Mehta',     'rohan.mehta@learner.manipal.edu',   '$2b$12$xyz...hash3', 'Electronics', 3, 2024);

-- User preferences
INSERT INTO user_preferences (user_id, theme, timezone, notifications_email) VALUES
(1, 'dark', 'Asia/Kolkata', TRUE),
(2, 'light', 'Asia/Kolkata', TRUE),
(3, 'system', 'Asia/Kolkata', FALSE);

-- Courses
INSERT INTO courses (course_code, course_name, credits, department) VALUES
('CSE301', 'Database Management Systems', 4.0, 'Computer Science'),
('CSE302', 'Operating Systems',           4.0, 'Computer Science'),
('CSE303', 'Computer Networks',           3.0, 'Computer Science'),
('MAT201', 'Discrete Mathematics',        3.0, 'Mathematics'),
('CSE304', 'Software Engineering',        3.0, 'Computer Science');

-- Enrolments (user 1 enrolled in 4 courses)
INSERT INTO enrolments (user_id, course_id, semester, academic_year, final_grade, grade_points) VALUES
(1, 1, 5, 2024, 'A', 9.00),
(1, 2, 5, 2024, NULL, NULL),
(1, 3, 5, 2024, NULL, NULL),
(1, 4, 5, 2024, 'S', 10.00),
(2, 1, 5, 2024, NULL, NULL),
(2, 5, 5, 2024, NULL, NULL);

-- Assignments
INSERT INTO assignments (enrolment_id, title, max_marks, obtained_marks, weightage, due_date, is_submitted) VALUES
(1, 'ER Diagram Design',          25, 22.5, 10.0, '2024-09-15', TRUE),
(1, 'Normalization Assignment',   25, NULL, 10.0, '2024-10-20', FALSE),
(2, 'Process Scheduling Report',  30, 28.0, 15.0, '2024-09-30', TRUE),
(4, 'Graph Theory Problem Set',   20, 19.0, 10.0, '2024-09-10', TRUE);

-- Grade components
INSERT INTO grade_components (enrolment_id, component_name, max_marks, obtained_marks, weightage, conducted_on) VALUES
(1, 'CIE-1',    30, 27, 15.0, '2024-08-20'),
(1, 'CIE-2',    30, 25, 15.0, '2024-10-05'),
(1, 'Lab',      25, 23, 10.0, '2024-09-28'),
(1, 'SEE',      100, NULL, 60.0, NULL),
(2, 'CIE-1',    30, 29, 15.0, '2024-08-22');

-- Attendance
INSERT INTO attendance_records (enrolment_id, class_date, is_present) VALUES
(1, '2024-08-05', TRUE), (1, '2024-08-07', TRUE), (1, '2024-08-09', FALSE),
(1, '2024-08-12', TRUE), (1, '2024-08-14', TRUE), (1, '2024-08-16', TRUE),
(2, '2024-08-06', TRUE), (2, '2024-08-08', FALSE),(2, '2024-08-10', TRUE);

-- Task labels
INSERT INTO task_labels (user_id, label_name, colour_hex) VALUES
(1, 'Urgent',  '#FF4444'),
(1, 'Study',   '#4A90E2'),
(1, 'Health',  '#27AE60'),
(1, 'Project', '#9B59B6');

-- Tasks
INSERT INTO tasks (user_id, title, status, priority, category, due_date, enrolment_id) VALUES
(1, 'Complete DBMS Normalization Assignment', 'pending',   'high',   'academic', '2024-10-20 23:59:00+05:30', 1),
(1, 'Revise OS Chapter 4 - Deadlocks',        'pending',   'medium', 'academic', '2024-10-15 20:00:00+05:30', 2),
(1, 'Submit Networks Lab Report',             'completed', 'high',   'academic', '2024-10-01 17:00:00+05:30', 3),
(1, 'Morning run - 5km',                      'pending',   'low',    'fitness',  '2024-10-12 07:00:00+05:30', NULL),
(1, 'Buy stationery for exam',                'pending',   'low',    'personal', '2024-10-18 18:00:00+05:30', NULL),
(2, 'DBMS Project Proposal',                  'in_progress','high',  'academic', '2024-10-25 23:59:00+05:30', 5);

-- Task label mapping
INSERT INTO task_label_map (task_id, label_id) VALUES
(1, 1), (1, 2),  -- Task 1: Urgent + Study
(2, 2),          -- Task 2: Study
(4, 3),          -- Task 4: Health
(6, 4);          -- Task 6: Project

-- Events
INSERT INTO events (user_id, title, event_type, starts_at, ends_at, location, enrolment_id) VALUES
(1, 'DBMS CIE-3 Examination',     'exam',         '2024-11-05 09:00:00+05:30', '2024-11-05 11:00:00+05:30', 'LH-101', 1),
(1, 'OS Lab - Practical Session', 'lecture',      '2024-10-14 14:00:00+05:30', '2024-10-14 17:00:00+05:30', 'Lab B-4', 2),
(1, 'Hackathon Registration',     'personal',     '2024-10-20 10:00:00+05:30', '2024-10-20 17:00:00+05:30', 'Syndicate Block', NULL),
(1, 'Networks Assignment Due',    'assignment_due','2024-10-22 23:59:00+05:30', NULL,                        NULL,      3);

-- Reminders
INSERT INTO reminders (user_id, event_id, remind_at, message) VALUES
(1, 1, '2024-11-04 20:00:00+05:30', 'DBMS exam tomorrow at 9 AM — revise normalization!'),
(1, 3, '2024-10-19 09:00:00+05:30', 'Register for hackathon tomorrow');

INSERT INTO reminders (user_id, task_id, remind_at, message) VALUES
(1, 1, '2024-10-19 18:00:00+05:30', 'Normalization assignment due tomorrow night!');

-- Notes
INSERT INTO note_folders (user_id, folder_name) VALUES
(1, 'DBMS'),
(1, 'OS'),
(1, 'Personal');

INSERT INTO notes (user_id, folder_id, enrolment_id, title, content, is_pinned) VALUES
(1, 1, 1, 'Normalization Notes', '## 1NF\nEnsure atomic values...\n## 2NF\nRemove partial dependencies...', TRUE),
(1, 1, 1, 'SQL Join Types',      'INNER JOIN returns matching rows...',                                   FALSE),
(1, 2, 2, 'Process States',      'New → Ready → Running → Waiting → Terminated',                         TRUE),
(1, 3, NULL,'Hackathon Ideas',   'Project idea: Student dashboard with ML-based grade prediction',        FALSE);

-- Projects
INSERT INTO projects (user_id, title, description, tech_stack, status, start_date) VALUES
(1, 'Student Tracker App', 'Full-stack student productivity tool', ARRAY['React','Node.js','PostgreSQL','Redis'], 'active', '2024-08-01'),
(1, 'ML Grade Predictor',  'Predicts semester GPA from past data', ARRAY['Python','scikit-learn','Flask'],        'planning', '2024-10-01');

INSERT INTO project_milestones (project_id, title, due_date, is_completed) VALUES
(1, 'DB Schema Design',    '2024-08-15', TRUE),
(1, 'Backend API v1',      '2024-09-15', TRUE),
(1, 'Frontend Dashboard',  '2024-10-15', FALSE),
(1, 'Beta Launch',         '2024-11-01', FALSE);

-- Fitness logs
INSERT INTO fitness_daily_logs (user_id, log_date, steps, calories_burned, calories_intake, active_minutes, water_ml, sleep_hours, weight_kg) VALUES
(1, '2024-10-07', 8200,  420, 2100, 55, 2500, 7.5, 68.5),
(1, '2024-10-08', 10500, 530, 1950, 70, 2800, 6.0, 68.3),
(1, '2024-10-09', 6800,  340, 2300, 40, 2000, 8.0, 68.4),
(1, '2024-10-10', 12000, 600, 2050, 85, 3000, 7.0, 68.1),
(1, '2024-10-11', 9400,  470, 2200, 60, 2600, 7.5, 68.2);

INSERT INTO fitness_goals (user_id, goal_type, target_value, effective_from) VALUES
(1, 'steps',    10000, '2024-10-01'),
(1, 'water',    3000,  '2024-10-01'),
(1, 'sleep',    8,     '2024-10-01'),
(1, 'calories', 500,   '2024-10-01');

INSERT INTO workout_sessions (user_id, workout_type, duration_mins, calories_burned, distance_km, performed_at) VALUES
(1, 'Running',  35, 320, 5.2, '2024-10-08 06:30:00+05:30'),
(1, 'Gym',      60, 450, NULL,'2024-10-10 07:00:00+05:30'),
(1, 'Yoga',     30, 120, NULL,'2024-10-11 06:45:00+05:30');

-- Mood logs
INSERT INTO mood_logs (user_id, mood, energy_level, stress_level, notes) VALUES
(1, 'happy',    7, 4, 'Finished the OS assignment — feeling good'),
(1, 'neutral',  5, 6, NULL),
(1, 'sad',      3, 8, 'Exam stress is building up'),
(1, 'happy',    8, 3, 'Got 22.5/25 in ER diagram!'),
(1, 'neutral',  6, 5, NULL);

-- Notifications
INSERT INTO notifications (user_id, type, title, body, source_table, source_id) VALUES
(1, 'grade_update', 'Grade Posted: DBMS Assignment',  'You scored 22.5/25 on ER Diagram Design',             'assignments', 1),
(1, 'task_due',     'Task Due Tomorrow',               'Normalization Assignment is due in 24 hours',         'tasks',       1),
(1, 'reminder',     'Exam Tomorrow: DBMS CIE-3',       'Your DBMS exam is at 9:00 AM in LH-101',             'events',      1),
(1, 'system',       'Weekly Report Ready',             'Your weekly summary is available for download',       NULL,          NULL);
