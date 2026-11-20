-- How many users are in the dataset?
SELECT COUNT(DISTINCT Id) AS users
FROM daily_activity;

-- How many days of data did each user log?
SELECT Id, COUNT(*) AS days_logged
FROM daily_activity
GROUP BY Id
ORDER BY days_logged;

-- Days with zero steps (device probably synced but not worn)
SELECT COUNT(*) AS zero_step_days
FROM daily_activity
WHERE TotalSteps = 0;

-- Zero-step days as a percentage of all days
SELECT ROUND(100.0 * SUM(TotalSteps = 0) / COUNT(*), 1) AS pct_zero_step_days
FROM daily_activity;

-- How many users tracked sleep at least once?
SELECT COUNT(DISTINCT Id) AS sleep_users
FROM sleep_day;


-- ---------------------------------------------------------------------
-- 2. Sleep tracking and wear time
-- ---------------------------------------------------------------------

-- Average hours tracked per day, per user (all activity minutes / 60)
SELECT Id,
       ROUND(AVG(VeryActiveMinutes + FairlyActiveMinutes
                 + LightlyActiveMinutes + SedentaryMinutes) / 60.0, 1) AS avg_hours_tracked
FROM daily_activity
GROUP BY Id
ORDER BY avg_hours_tracked;

-- Compare sleep trackers with non-sleep trackers
-- Note: non-sleep users looked higher because sleep minutes are stored
-- separately for sleep trackers (see next query)
SELECT CASE WHEN Id IN (SELECT Id FROM sleep_day) THEN 'Tracks sleep'
            ELSE 'No sleep data' END AS user_group,
       COUNT(DISTINCT Id) AS users,
       ROUND(AVG(VeryActiveMinutes + FairlyActiveMinutes
                 + LightlyActiveMinutes + SedentaryMinutes) / 60.0, 1) AS avg_hours_tracked
FROM daily_activity
GROUP BY user_group;

-- Sleep trackers: activity hours + time in bed on nights with sleep logged
-- Result: 16.3h activity + 7.2h in bed = 23.5h, so near-24h wear
WITH nightly_sleep AS (
  SELECT Id,
         SUBSTR(date, 1, INSTR(date, ' ') - 1) AS sleep_date,   -- strip the time from the date
         COUNT(*) AS minutes_in_bed                              -- one row = one minute
  FROM sleep_day
  GROUP BY Id, sleep_date
)
SELECT ROUND(AVG(d.VeryActiveMinutes + d.FairlyActiveMinutes
                 + d.LightlyActiveMinutes + d.SedentaryMinutes) / 60.0, 1) AS avg_activity_hours,
       ROUND(AVG(n.minutes_in_bed) / 60.0, 1) AS avg_hours_in_bed,
       ROUND(AVG(d.VeryActiveMinutes + d.FairlyActiveMinutes
                 + d.LightlyActiveMinutes + d.SedentaryMinutes
                 + n.minutes_in_bed) / 60.0, 1) AS avg_total_hours
FROM daily_activity AS d
JOIN nightly_sleep AS n
  ON d.Id = n.Id
 AND d.ActivityDate = n.sleep_date;


-- ---------------------------------------------------------------------
-- 3. Data cleaning: convert text dates (e.g. 4/12/2016) to 2016-04-12
-- ---------------------------------------------------------------------

CREATE TABLE daily_clean AS
WITH parts AS (
  SELECT *,
         CAST(SUBSTR(ActivityDate, 1, INSTR(ActivityDate, '/') - 1) AS INTEGER) AS m,  -- month
         SUBSTR(ActivityDate, INSTR(ActivityDate, '/') + 1) AS rest                   -- "12/2016"
  FROM daily_activity
)
SELECT *,
       PRINTF('%s-%02d-%02d',
              SUBSTR(rest, INSTR(rest, '/') + 1),                          -- year
              m,                                                           -- month
              CAST(SUBSTR(rest, 1, INSTR(rest, '/') - 1) AS INTEGER)) AS activity_date  -- day
FROM parts;

-- Check the cleaned dates: first day, last day, number of days
SELECT MIN(activity_date) AS first_day,
       MAX(activity_date) AS last_day,
       COUNT(DISTINCT activity_date) AS days
FROM daily_clean;


-- ---------------------------------------------------------------------
-- 4. Engagement over time
-- ---------------------------------------------------------------------

-- Daily active users by calendar date (users with at least 1 step)
-- Showed a sharp jump on 1 April, caused by users joining, not more use
SELECT activity_date,
       COUNT(DISTINCT Id) AS active_users
FROM daily_clean
WHERE TotalSteps > 0
GROUP BY activity_date
ORDER BY activity_date;

-- When did each user start? (confirms most users joined around 1 April)
SELECT first_date, COUNT(*) AS users_starting
FROM (
  SELECT Id, MIN(activity_date) AS first_date
  FROM daily_clean
  GROUP BY Id
)
GROUP BY first_date
ORDER BY first_date;

-- Retention view: active users by day since each user's first day
-- Uses a window function to find each user's start date without grouping
WITH user_days AS (
  SELECT Id, activity_date, TotalSteps,
         JULIANDAY(activity_date)
           - JULIANDAY(MIN(activity_date) OVER (PARTITION BY Id)) + 1 AS day_number
  FROM daily_clean
)
SELECT day_number,
       COUNT(DISTINCT CASE WHEN TotalSteps > 0 THEN Id END) AS active_users
FROM user_days
GROUP BY day_number
ORDER BY day_number;


-- ---------------------------------------------------------------------
-- 5. How much data does each user have? (explains the drop after day 11)
-- ---------------------------------------------------------------------

-- First date, last date and date span per user
SELECT Id,
       MIN(activity_date) AS first_date,
       MAX(activity_date) AS last_date,
       JULIANDAY(MAX(activity_date)) - JULIANDAY(MIN(activity_date)) + 1 AS days_span
FROM daily_clean
GROUP BY Id
ORDER BY last_date, first_date;

-- Days of data vs days actually worn, per user
SELECT Id,
       COUNT(*) AS data_days,
       SUM(TotalSteps > 0) AS days_worn,
       MIN(activity_date) AS first_date,
       MAX(activity_date) AS last_date
FROM daily_clean
GROUP BY Id
ORDER BY data_days;

-- Number of users by days of data (chart: most users have 12 days or fewer)
SELECT data_days, COUNT(*) AS users
FROM (
  SELECT Id, COUNT(*) AS data_days
  FROM daily_clean
  GROUP BY Id
)
GROUP BY data_days
ORDER BY data_days;


-- ---------------------------------------------------------------------
-- 6. Users who rarely wore their device
-- ---------------------------------------------------------------------

-- Users with at least one day not worn (HAVING filters after grouping)
SELECT Id,
       COUNT(*) AS data_days,
       SUM(TotalSteps > 0) AS days_worn,
       COUNT(*) - SUM(TotalSteps > 0) AS days_not_worn
FROM daily_clean
GROUP BY Id
HAVING days_not_worn > 0
ORDER BY days_not_worn DESC;


-- ---------------------------------------------------------------------
-- 7. Segmentation: engagement level vs sleep tracking and activity
-- ---------------------------------------------------------------------

-- Low (<50% of days worn), Medium (50-99%), High (100%)
-- Result: sleep tracking 0% / 60% / 81%; steps 5,065 / 6,887 / 8,002
WITH user_wear AS (
  SELECT Id,
         100.0 * SUM(TotalSteps > 0) / COUNT(*) AS pct_days_worn,
         AVG(CASE WHEN TotalSteps > 0 THEN TotalSteps END) AS avg_steps_when_worn
  FROM daily_clean
  GROUP BY Id
),
segmented AS (
  SELECT *,
         CASE WHEN pct_days_worn < 50 THEN '1. Low (<50%)'
              WHEN pct_days_worn < 100 THEN '2. Medium (50-99%)'
              ELSE '3. High (100%)' END AS segment
  FROM user_wear
)
SELECT segment,
       COUNT(*) AS users,
       SUM(Id IN (SELECT Id FROM sleep_day)) AS sleep_trackers,
       ROUND(100.0 * SUM(Id IN (SELECT Id FROM sleep_day)) / COUNT(*), 0) AS pct_tracking_sleep,
       ROUND(AVG(avg_steps_when_worn), 0) AS avg_steps_when_worn
FROM segmented
GROUP BY segment
ORDER BY segment;
