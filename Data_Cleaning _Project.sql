-- =====================================================================
-- PROJECT   : World Layoffs - SQL Data Cleaning
-- DATABASE  : MySQL (tested logic for MySQL 8+)
-- DATASET   : Global layoffs data (table: layoffs)
-- PURPOSE   : Turn a raw, messy layoffs table into an analysis-ready table
--
-- WORKFLOW
--   1. Create a staging table (never clean the raw table directly)
--   2. Remove duplicates
--   3. Standardize the data (text, country names, date format)
--   4. Handle NULL and blank values
--   5. Remove unnecessary rows / columns
-- =====================================================================

USE data_cleaning;

-- Quick look at the raw data
SELECT * FROM layoffs;


-- =====================================================================
-- STEP 0: CREATE STAGING TABLE
-- Why: keep the raw table untouched in case something goes wrong.
-- =====================================================================

-- Copy only the structure of the raw table
CREATE TABLE layoffs_staging
LIKE layoffs;

-- Copy all the data into the staging table
INSERT INTO layoffs_staging
SELECT * FROM layoffs;

-- Check that the copy worked (row counts should match)
SELECT COUNT(*) AS raw_rows FROM layoffs;
SELECT COUNT(*) AS staging_rows FROM layoffs_staging;


-- =====================================================================
-- STEP 1: REMOVE DUPLICATES
-- The table has no unique ID, so we detect duplicates by numbering rows
-- that share the same values in ALL columns. row_num > 1 = duplicate.
--
-- FIX: `date` must be in BACKTICKS. In the original code it was in single
-- quotes ('date'), which MySQL treats as a text string, not the column,
-- so the date was never used to detect duplicates.
-- =====================================================================

-- 1a. Find duplicates (preview only)
WITH duplicate_cte AS
(
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY company, location, industry, total_laid_off,
                            percentage_laid_off, `date`, stage, country,
                            funds_raised_millions
           ) AS row_num
    FROM layoffs_staging
)
SELECT *
FROM duplicate_cte
WHERE row_num > 1;

-- 1b. Verify one duplicate example before deleting anything
SELECT *
FROM layoffs_staging
WHERE company = 'Casper';

-- 1c. MySQL cannot DELETE directly from a CTE, so we create a second
--     staging table that has an extra row_num column, then delete from it.
CREATE TABLE `layoffs_staging2` (
  `company` text,
  `location` text,
  `industry` text,
  `total_laid_off` double DEFAULT NULL,
  `percentage_laid_off` text,
  `date` text,
  `stage` text,
  `country` text,
  `funds_raised_millions` int DEFAULT NULL,
  `row_num` INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 1d. Insert all rows along with their row_num
INSERT INTO layoffs_staging2
SELECT *,
       ROW_NUMBER() OVER (
           PARTITION BY company, location, industry, total_laid_off,
                        percentage_laid_off, `date`, stage, country,
                        funds_raised_millions
       ) AS row_num
FROM layoffs_staging;

-- 1e. Check the duplicates one more time
SELECT *
FROM layoffs_staging2
WHERE row_num > 1;

-- 1f. Delete the duplicates
DELETE
FROM layoffs_staging2
WHERE row_num > 1;

-- 1g. Confirm that no duplicates remain (should return 0 rows)
SELECT *
FROM layoffs_staging2
WHERE row_num > 1;


-- =====================================================================
-- STEP 2: STANDARDIZE THE DATA
-- =====================================================================

-- ---------- 2a. Company: remove extra spaces ----------
-- Preview the change
SELECT company, TRIM(company)
FROM layoffs_staging2;

UPDATE layoffs_staging2
SET company = TRIM(company);


-- ---------- 2b. Industry: merge similar values ----------
-- Look at all distinct industries (spot variants such as Crypto / CryptoCurrency)
SELECT DISTINCT industry
FROM layoffs_staging2
ORDER BY 1;

SELECT *
FROM layoffs_staging2
WHERE industry LIKE 'Crypto%';

-- Standardize all Crypto variants to one label
UPDATE layoffs_staging2
SET industry = 'Crypto'
WHERE industry LIKE 'Crypto%';


-- ---------- 2c. Location: just review for issues ----------
SELECT DISTINCT location
FROM layoffs_staging2
ORDER BY 1;


-- ---------- 2d. Country: fix trailing dots ("United States." -> "United States") ----------
SELECT DISTINCT country
FROM layoffs_staging2
ORDER BY 1;

-- Preview the fix
SELECT DISTINCT country, TRIM(TRAILING '.' FROM country)
FROM layoffs_staging2
ORDER BY 1;

UPDATE layoffs_staging2
SET country = TRIM(TRAILING '.' FROM country)
WHERE country LIKE 'United States%';


-- ---------- 2e. Date: convert text to a real DATE ----------
-- The date column was imported as text (e.g. 3/15/2022).
-- Preview the conversion
SELECT `date`,
       STR_TO_DATE(`date`, '%m/%d/%Y') AS converted_date
FROM layoffs_staging2;

-- Convert the values (format: month/day/year)
UPDATE layoffs_staging2
SET `date` = STR_TO_DATE(`date`, '%m/%d/%Y');

-- Change the column data type from TEXT to DATE
-- (do this only AFTER the UPDATE above)
ALTER TABLE layoffs_staging2
MODIFY COLUMN `date` DATE;

-- Verify the new data type
DESCRIBE layoffs_staging2;


-- =====================================================================
-- STEP 3: HANDLE NULL AND BLANK VALUES
-- =====================================================================

-- ---------- 3a. Review rows with no layoff information ----------
SELECT *
FROM layoffs_staging2
WHERE total_laid_off IS NULL
  AND percentage_laid_off IS NULL;

-- ---------- 3b. Industry: convert blank strings to NULL ----------
-- Treating blanks as NULL makes the later checks and joins simpler.
UPDATE layoffs_staging2
SET industry = NULL
WHERE industry = '';

-- See which rows are missing an industry
SELECT *
FROM layoffs_staging2
WHERE industry IS NULL
   OR industry = '';

-- Example: Airbnb has one row with industry filled and one without
SELECT *
FROM layoffs_staging2
WHERE company = 'Airbnb';

-- ---------- 3c. Fill missing industry using other rows of the same company ----------
-- FIX: the original joined to layoffs_staging (the old table where blanks
-- were still ''), which could copy a blank value back in.
-- Now we self-join layoffs_staging2 and also skip blank values.

-- Preview what will be filled
SELECT t1.company, t1.industry AS missing_industry, t2.industry AS known_industry
FROM layoffs_staging2 t1
JOIN layoffs_staging2 t2
  ON t1.company = t2.company
WHERE t1.industry IS NULL
  AND t2.industry IS NOT NULL
  AND t2.industry <> ''
ORDER BY t1.company;

-- Apply the update
UPDATE layoffs_staging2 t1
JOIN layoffs_staging2 t2
  ON t1.company = t2.company
SET t1.industry = t2.industry
WHERE t1.industry IS NULL
  AND t2.industry IS NOT NULL
  AND t2.industry <> '';

-- ---------- 3d. Check what is still missing ----------
SELECT *
FROM layoffs_staging2
WHERE industry IS NULL;

-- Manual fixes for companies that have no other row to copy from.
-- NOTE: these values come from outside knowledge of each company.
-- Re-check the output of the query above on your own data before running.
UPDATE layoffs_staging2
SET industry = 'Travel'
WHERE company = 'Airbnb';

UPDATE layoffs_staging2
SET industry = 'Consumer'
WHERE company = 'Juul';

-- Confirm the result of the manual fixes
SELECT *
FROM layoffs_staging2
WHERE company IN ('Airbnb', 'Juul');

-- Any company still showing NULL here has no way to be filled from the data.
-- Decide whether to research it manually or leave it as NULL.
SELECT *
FROM layoffs_staging2
WHERE industry IS NULL;


-- =====================================================================
-- STEP 4: REMOVE UNNECESSARY ROWS AND COLUMNS
-- =====================================================================

-- Rows where BOTH total_laid_off and percentage_laid_off are NULL
-- give no layoff information, so they are not useful for analysis.
SELECT *
FROM layoffs_staging2
WHERE total_laid_off IS NULL
  AND percentage_laid_off IS NULL;

DELETE
FROM layoffs_staging2
WHERE total_laid_off IS NULL
  AND percentage_laid_off IS NULL;

-- row_num was only a helper column for finding duplicates; drop it
ALTER TABLE layoffs_staging2
DROP COLUMN row_num;


-- =====================================================================
-- FINAL CHECK
-- layoffs_staging2 is now the cleaned table.
-- =====================================================================
SELECT * FROM layoffs_staging2;

-- Compare row counts: raw vs cleaned 
SELECT
    (SELECT COUNT(*) FROM layoffs)          AS raw_rows,
    (SELECT COUNT(*) FROM layoffs_staging2) AS cleaned_rows;