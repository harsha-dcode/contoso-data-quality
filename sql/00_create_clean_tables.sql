/* =====================================================================
   00_create_clean_tables.sql
   Contoso India — the clean layer, typed and loaded from data/clean/

   Run this if you only want the analysis. It is the shortcut the README
   offers: data/clean/ is committed, so steps 1-3 can be skipped and
   04_analysis.sql will run against what this script builds.

   Full pipeline order is 01 -> 02 -> 03 -> 04. This file is 00 because it
   is an alternative entry point, not a step between them.
   ---------------------------------------------------------------------
   WHY THIS FILE EXISTS

   The clean tables are produced by 03_cleaning.ipynb, which writes CSVs
   with pandas. pandas knows the dtypes; a CSV does not carry them. So
   anyone loading data/clean/ through the SSMS Import Wizard got whatever
   the wizard guessed, and the wizard guesses badly on this data in two
   places that matter:

     ShippingDays   4,713 rows are empty, and the import wizard will
                    happily make the column NVARCHAR. Then line 401 of
                    04_analysis.sql does CAST(ShippingDays AS FLOAT), and
                    CAST('' AS FLOAT) is 0.0, not NULL. AvgShipDays comes
                    out too low and nothing errors. INT NULL is the only
                    type that makes AVG skip those rows, which is the
                    whole point of the IsShippingKnown flag.

     the five flags stored as the text TRUE/FALSE, but 04_analysis.sql
                    treats them as numbers: LossFlag = 1 in six places and
                    SUM(FailsPricingRule) on line 662. NVARCHAR fails the
                    comparison; BIT passes the comparison and then fails
                    the SUM, because SUM is not defined on bit. TINYINT is
                    the type that does both.

   So the types are declared here rather than left to a wizard. Every one
   of them was read off the files, not assumed - see the note at the end.
   ---------------------------------------------------------------------
   PATHS

   BULK INSERT runs as the SQL Server service account and does not accept
   relative paths, so the folder has to be one that account can read.
   A path inside a user profile or OneDrive usually fails with
   "Operating system error code 5 (Access is denied)".

   Before running: copy the seven CSVs from data/clean/ into
   C:\Data\contoso\clean\, or find-and-replace that folder below
   (7 occurrences).
   ===================================================================== */


IF DB_ID('ContosoRetail') IS NULL
    CREATE DATABASE ContosoRetail;
GO

USE ContosoRetail;
GO


/* ---------- 1. Drop in dependency order ------------------------------
   Fact first. Dropping a parent while a child still references it fails
   with error 3726, and the fact table holds every foreign key here.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dbo.fact_sales;
DROP TABLE IF EXISTS dbo.dim_userregion;
DROP TABLE IF EXISTS dbo.dim_customer;
DROP TABLE IF EXISTS dbo.dim_product;
DROP TABLE IF EXISTS dbo.dim_channel;
DROP TABLE IF EXISTS dbo.dim_region;
DROP TABLE IF EXISTS dbo.dim_date;
GO


/* ---------- 2. Dimensions --------------------------------------------
   Keys verified unique on the files before being declared PRIMARY KEY:
   8,001 / 1,401 / 91 / 1,461 / 4 distinct, equal to the row counts.

   Nullable columns are nullable because the clean data has gaps there on
   purpose. dim_customer carries the UNKNOWN member that orphan customer
   keys were mapped to, and that row has no name, no dates and no city -
   mapping orphans to Unknown instead of dropping them is only honest if
   the Unknown row is allowed to be empty.
   --------------------------------------------------------------------- */
CREATE TABLE dbo.dim_region (
    RegionID    NVARCHAR(10)  NOT NULL,
    Region      NVARCHAR(50)  NOT NULL,
    Zone        NVARCHAR(20)  NOT NULL,
    State       NVARCHAR(50)  NOT NULL,
    City        NVARCHAR(50)  NOT NULL,
    Country     NVARCHAR(20)  NOT NULL,
    CONSTRAINT PK_dim_region PRIMARY KEY (RegionID)
);

CREATE TABLE dbo.dim_channel (
    ChannelID   NVARCHAR(10)  NOT NULL,
    Channel     NVARCHAR(30)  NOT NULL,
    ChannelType NVARCHAR(20)  NOT NULL,
    CONSTRAINT PK_dim_channel PRIMARY KEY (ChannelID)
);

CREATE TABLE dbo.dim_date (
    [Date]          DATE         NOT NULL,
    [Year]          INT          NOT NULL,
    Quarter         NVARCHAR(5)  NOT NULL,
    QuarterNumber   TINYINT      NOT NULL,
    [Month]         NVARCHAR(15) NOT NULL,
    MonthNumber     TINYINT      NOT NULL,
    YearMonth       NVARCHAR(10) NOT NULL,
    WeekNumber      TINYINT      NOT NULL,
    [Day]           TINYINT      NOT NULL,
    DayName         NVARCHAR(15) NOT NULL,
    DayOfWeekNumber TINYINT      NOT NULL,
    IsWeekend       NVARCHAR(5)  NOT NULL,   -- see section 5
    IsHoliday       NVARCHAR(5)  NOT NULL,   -- see section 5
    CONSTRAINT PK_dim_date PRIMARY KEY ([Date])
);

CREATE TABLE dbo.dim_customer (
    CustomerID     NVARCHAR(10)  NOT NULL,
    CustomerName   NVARCHAR(100) NULL,
    Gender         NVARCHAR(10)  NULL,
    DateOfBirth    DATE          NULL,
    Age            INT           NULL,
    AgeGroup       NVARCHAR(15)  NOT NULL,
    Segment        NVARCHAR(30)  NOT NULL,
    JoinDate       DATE          NULL,
    City           NVARCHAR(50)  NULL,
    State          NVARCHAR(50)  NULL,
    RegionID       NVARCHAR(10)  NULL,
    CustomerStatus NVARCHAR(15)  NULL,
    CONSTRAINT PK_dim_customer PRIMARY KEY (CustomerID)
);

CREATE TABLE dbo.dim_product (
    ProductID     NVARCHAR(10)  NOT NULL,
    ProductName   NVARCHAR(100) NOT NULL,
    Category      NVARCHAR(30)  NOT NULL,
    SubCategory   NVARCHAR(30)  NOT NULL,
    Brand         NVARCHAR(30)  NULL,
    LaunchDate    DATE          NULL,
    ProductStatus NVARCHAR(20)  NULL,
    StandardCost  DECIMAL(12,2) NULL,
    ListPrice     DECIMAL(12,2) NULL,
    CONSTRAINT PK_dim_product PRIMARY KEY (ProductID)
);

/* dim_userregion is row-level-security plumbing for the Power BI model,
   not an analysis dimension. One user maps to many regions, so the key is
   the pair - UserPrincipalName alone is 16 distinct values across 270
   rows and would reject the load as a primary key. */
CREATE TABLE dbo.dim_userregion (
    UserPrincipalName NVARCHAR(100) NOT NULL,
    UserName          NVARCHAR(50)  NOT NULL,
    RoleName          NVARCHAR(30)  NOT NULL,
    Zone              NVARCHAR(20)  NOT NULL,
    Region            NVARCHAR(50)  NOT NULL,
    RegionID          NVARCHAR(10)  NOT NULL,
    CONSTRAINT PK_dim_userregion PRIMARY KEY (UserPrincipalName, RegionID)
);
GO


/* ---------- 3. Fact table, created as a heap -------------------------
   No primary key and no indexes yet. BULK INSERT into a heap with TABLOCK
   is minimally logged and avoids sorting 157k rows into an index that is
   about to be rebuilt anyway. The key and the indexes go on in section 6,
   after the data is in.

   Money columns are DECIMAL, not FLOAT. Every figure in docs/ is a rupee
   total that has to reconcile against Profit = Sales - Cost; binary
   floating point would make those checks fail by small amounts for no
   reason. Scale 2 was read off the files - no value has more than two
   decimal places.

   The five flags are declared NVARCHAR(5) because that is what is in the
   file - the literal text TRUE and FALSE. Section 5 converts them.
   --------------------------------------------------------------------- */
CREATE TABLE dbo.fact_sales (
    OrderID          NVARCHAR(20)  NOT NULL,
    OrderLineID      NVARCHAR(25)  NOT NULL,
    OrderDate        DATE          NOT NULL,
    CustomerID       NVARCHAR(10)  NOT NULL,
    ProductID        NVARCHAR(10)  NOT NULL,
    RegionID         NVARCHAR(10)  NOT NULL,
    ChannelID        NVARCHAR(10)  NOT NULL,
    Quantity         INT           NOT NULL,
    UnitPrice        DECIMAL(12,2) NOT NULL,
    DiscountPercent  DECIMAL(5,2)  NOT NULL,
    SalesAmount      DECIMAL(14,2) NOT NULL,
    CostAmount       DECIMAL(14,2) NOT NULL,
    ProfitAmount     DECIMAL(14,2) NOT NULL,
    PaymentMethod    NVARCHAR(20)  NULL,
    OrderStatus      NVARCHAR(15)  NOT NULL,
    ReturnFlag       NVARCHAR(5)   NOT NULL,   -- see section 5
    ShippingDays     INT           NULL,
    IsShippingKnown  NVARCHAR(5)   NOT NULL,   -- see section 5
    RecoveredField   NVARCHAR(20)  NULL,
    LossFlag         NVARCHAR(5)   NOT NULL,   -- see section 5
    DiscountBand     NVARCHAR(10)  NOT NULL,
    LineMarginPct    DECIMAL(9,2)  NOT NULL,
    FailsPricingRule NVARCHAR(5)   NOT NULL,   -- see section 5
    FailsProfitRule  NVARCHAR(5)   NOT NULL    -- see section 5
);
GO


/* ---------- 4. Load --------------------------------------------------
   KEEPNULLS is what turns an empty CSV field into NULL instead of into
   the column default. It is the reason ShippingDays ends up with 4,713
   NULLs rather than 4,713 zeros. Section 7 asserts that count.

   ROWTERMINATOR is 0x0d0a because these files are CRLF. With 0x0a the
   last column of every row keeps a trailing \r, which on a DATE or INT
   column fails the whole load and on an NVARCHAR column fails nothing
   and corrupts everything.
   --------------------------------------------------------------------- */
BULK INSERT dbo.dim_region
FROM 'C:\Data\contoso\clean\dim_region.csv'
WITH (FORMAT = 'CSV', FIELDQUOTE = '"', FIRSTROW = 2,
      FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0d0a',
      CODEPAGE = '65001', KEEPNULLS);

BULK INSERT dbo.dim_channel
FROM 'C:\Data\contoso\clean\dim_channel.csv'
WITH (FORMAT = 'CSV', FIELDQUOTE = '"', FIRSTROW = 2,
      FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0d0a',
      CODEPAGE = '65001', KEEPNULLS);

BULK INSERT dbo.dim_date
FROM 'C:\Data\contoso\clean\dim_date.csv'
WITH (FORMAT = 'CSV', FIELDQUOTE = '"', FIRSTROW = 2,
      FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0d0a',
      CODEPAGE = '65001', KEEPNULLS);

BULK INSERT dbo.dim_customer
FROM 'C:\Data\contoso\clean\dim_customer.csv'
WITH (FORMAT = 'CSV', FIELDQUOTE = '"', FIRSTROW = 2,
      FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0d0a',
      CODEPAGE = '65001', KEEPNULLS);

BULK INSERT dbo.dim_product
FROM 'C:\Data\contoso\clean\dim_product.csv'
WITH (FORMAT = 'CSV', FIELDQUOTE = '"', FIRSTROW = 2,
      FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0d0a',
      CODEPAGE = '65001', KEEPNULLS);

BULK INSERT dbo.dim_userregion
FROM 'C:\Data\contoso\clean\dim_userregion.csv'
WITH (FORMAT = 'CSV', FIELDQUOTE = '"', FIRSTROW = 2,
      FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0d0a',
      CODEPAGE = '65001', KEEPNULLS);

BULK INSERT dbo.fact_sales
FROM 'C:\Data\contoso\clean\fact_sales.csv'
WITH (FORMAT = 'CSV', FIELDQUOTE = '"', FIRSTROW = 2,
      FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0d0a',
      CODEPAGE = '65001', KEEPNULLS, TABLOCK);
GO


/* ---------- 5. Booleans: text -> number ------------------------------
   WHY THE FLAGS ARE NOT LOADED AS BIT DIRECTLY

   T-SQL converts the strings 'TRUE' and 'FALSE' to bit - CAST('TRUE' AS
   BIT) returns 1, and that is documented. BULK INSERT does not use that
   conversion. It goes through the OLE DB bulk provider, which only
   accepts 0 and 1 for a bit column, and declaring the column BIT fails
   the load with

       Msg 4864 - Bulk load data conversion error (type mismatch or
       invalid character for the specified codepage) for row 2,
       column 12 (IsWeekend).

   I wrote this script with BIT first and that is the error it gave. The
   two conversions are not the same conversion, which is easy to assume
   and wrong.

   So the text is loaded as text and converted here. For the fact flags
   the target is TINYINT rather than BIT, because 04_analysis.sql uses
   them as numbers in two different ways:

       CASE WHEN LossFlag = 1 ...        lines 140, 143, 164, 254, 309, 312
       SUM(FailsPricingRule)             line 662

   bit satisfies the first and fails the second with "Operand data type
   bit is invalid for sum operator". tinyint satisfies both.

   dim_date's two flags are only ever filters, never summed, so they end
   up as BIT - the narrower and more honest type for a true/false column.

   The comparison is written in lower case on purpose. The clean files are
   inconsistent: ReturnFlag is 'TRUE'/'FALSE' and LossFlag is
   'True'/'False'. A case-insensitive collation - the default - matches
   both with one predicate. On a BIN2 collation it would match neither,
   which is the same trap 02_validation.sql documents from the other side.

   Flags stay NOT NULL. A flag that can be NULL has three states, and
   SUM() would then skip rows instead of counting them as 0.
   --------------------------------------------------------------------- */
UPDATE dbo.fact_sales
SET ReturnFlag       = CASE WHEN ReturnFlag       = 'true' THEN '1' ELSE '0' END,
    IsShippingKnown  = CASE WHEN IsShippingKnown  = 'true' THEN '1' ELSE '0' END,
    LossFlag         = CASE WHEN LossFlag         = 'true' THEN '1' ELSE '0' END,
    FailsPricingRule = CASE WHEN FailsPricingRule = 'true' THEN '1' ELSE '0' END,
    FailsProfitRule  = CASE WHEN FailsProfitRule  = 'true' THEN '1' ELSE '0' END;

UPDATE dbo.dim_date
SET IsWeekend = CASE WHEN IsWeekend = 'true' THEN '1' ELSE '0' END,
    IsHoliday = CASE WHEN IsHoliday = 'true' THEN '1' ELSE '0' END;
GO

ALTER TABLE dbo.fact_sales ALTER COLUMN ReturnFlag       TINYINT NOT NULL;
ALTER TABLE dbo.fact_sales ALTER COLUMN IsShippingKnown  TINYINT NOT NULL;
ALTER TABLE dbo.fact_sales ALTER COLUMN LossFlag         TINYINT NOT NULL;
ALTER TABLE dbo.fact_sales ALTER COLUMN FailsPricingRule TINYINT NOT NULL;
ALTER TABLE dbo.fact_sales ALTER COLUMN FailsProfitRule  TINYINT NOT NULL;

ALTER TABLE dbo.dim_date ALTER COLUMN IsWeekend BIT NOT NULL;
ALTER TABLE dbo.dim_date ALTER COLUMN IsHoliday BIT NOT NULL;
GO


/* ---------- 6. Keys and indexes, after the load ----------------------
   CLUSTERED on OrderDate, not on the primary key. The clustered index
   decides physical row order, and almost every query in 04_analysis.sql
   filters or groups by date - year over year, month over month, moving
   averages, cohorts. Clustering on OrderDate turns those into range
   scans. OrderLineID is unique and needed as the key, but nothing ever
   asks for a single order line, so it gets a nonclustered key instead.

   The three foreign keys were checked against the files first: zero
   orphans on CustomerID, ProductID, RegionID, ChannelID and OrderDate.
   They hold because orphans were mapped to Unknown members in cleaning
   rather than dropped, which is exactly what the constraint now proves.
   --------------------------------------------------------------------- */
CREATE CLUSTERED INDEX CIX_fact_sales_OrderDate
    ON dbo.fact_sales (OrderDate);

ALTER TABLE dbo.fact_sales
    ADD CONSTRAINT PK_fact_sales PRIMARY KEY NONCLUSTERED (OrderLineID);

ALTER TABLE dbo.fact_sales ADD
    CONSTRAINT FK_fact_customer FOREIGN KEY (CustomerID) REFERENCES dbo.dim_customer (CustomerID),
    CONSTRAINT FK_fact_product  FOREIGN KEY (ProductID)  REFERENCES dbo.dim_product  (ProductID),
    CONSTRAINT FK_fact_region   FOREIGN KEY (RegionID)   REFERENCES dbo.dim_region   (RegionID),
    CONSTRAINT FK_fact_channel  FOREIGN KEY (ChannelID)  REFERENCES dbo.dim_channel  (ChannelID),
    CONSTRAINT FK_fact_date     FOREIGN KEY (OrderDate)  REFERENCES dbo.dim_date     ([Date]);

/* Covering index for the product and category questions - Q2, Q4, Q8.
   The INCLUDE columns are the ones those queries aggregate, so the index
   answers them without touching the table. */
CREATE NONCLUSTERED INDEX IX_fact_sales_Product
    ON dbo.fact_sales (ProductID)
    INCLUDE (SalesAmount, ProfitAmount, CostAmount, Quantity, LossFlag, OrderStatus);

CREATE NONCLUSTERED INDEX IX_fact_sales_Customer
    ON dbo.fact_sales (CustomerID)
    INCLUDE (OrderID, OrderDate, SalesAmount, OrderStatus);
GO


/* ---------- 7. Verify ------------------------------------------------
   Expected values are from the committed files, counted outside SQL
   Server. Any MISMATCH means the load is short or the types silently
   dropped rows, and nothing computed afterwards can be trusted.
   --------------------------------------------------------------------- */
SELECT 'fact_sales'     AS TableName, COUNT(*) AS Loaded, 157108 AS Expected,
       CASE WHEN COUNT(*) = 157108 THEN 'OK' ELSE '*** MISMATCH ***' END AS Result
FROM dbo.fact_sales
UNION ALL SELECT 'dim_customer',   COUNT(*), 8001,
       CASE WHEN COUNT(*) = 8001 THEN 'OK' ELSE '*** MISMATCH ***' END FROM dbo.dim_customer
UNION ALL SELECT 'dim_product',    COUNT(*), 1401,
       CASE WHEN COUNT(*) = 1401 THEN 'OK' ELSE '*** MISMATCH ***' END FROM dbo.dim_product
UNION ALL SELECT 'dim_region',     COUNT(*),   91,
       CASE WHEN COUNT(*) =   91 THEN 'OK' ELSE '*** MISMATCH ***' END FROM dbo.dim_region
UNION ALL SELECT 'dim_date',       COUNT(*), 1461,
       CASE WHEN COUNT(*) = 1461 THEN 'OK' ELSE '*** MISMATCH ***' END FROM dbo.dim_date
UNION ALL SELECT 'dim_channel',    COUNT(*),    4,
       CASE WHEN COUNT(*) =    4 THEN 'OK' ELSE '*** MISMATCH ***' END FROM dbo.dim_channel
UNION ALL SELECT 'dim_userregion', COUNT(*),  270,
       CASE WHEN COUNT(*) =  270 THEN 'OK' ELSE '*** MISMATCH ***' END FROM dbo.dim_userregion;
GO

/* The three populations the README defines. If these do not match, the
   revenue figures in docs/ will not either. */
SELECT 'net (Completed)'              AS Basis, COUNT(*) AS Lines, 146055 AS Expected
FROM   dbo.fact_sales WHERE OrderStatus = 'Completed'
UNION ALL
SELECT 'placed (Completed+Returned)', COUNT(*), 152274
FROM   dbo.fact_sales WHERE OrderStatus IN ('Completed', 'Returned')
UNION ALL
SELECT 'all', COUNT(*), 157108
FROM   dbo.fact_sales;
GO

/* Flags and nulls. ShippingDaysNull must be 4,713. A zero there means
   KEEPNULLS did not take and the empty strings became 0 - the silent
   failure this whole script exists to prevent. */
SELECT SUM(CAST(LossFlag AS INT))         AS LossLines,        -- 17418
       SUM(CAST(ReturnFlag AS INT))       AS ReturnLines,      --  6231
       SUM(CAST(IsShippingKnown AS INT))  AS ShippingKnown,    -- 152395
       SUM(CAST(FailsPricingRule AS INT)) AS PricingBreaches,  --   700
       SUM(CAST(FailsProfitRule AS INT))  AS ProfitBreaches,   --   349
       COUNT(*) - COUNT(ShippingDays)     AS ShippingDaysNull, --  4713
       COUNT(RecoveredField)              AS RecoveredRows     --    16
FROM   dbo.fact_sales;
GO


/* =====================================================================
   WHERE THE TYPES CAME FROM

   Every column above was profiled on the committed CSVs before being
   declared: max string length, blank count, distinct count, and whether
   all non-blank values parse as a date, an integer or a decimal. The
   lengths are the next sensible size above the observed maximum, not
   NVARCHAR(50) everywhere.

   Three results worth keeping:

     - no money column has more than 2 decimal places, so DECIMAL(_,2)
       loses nothing
     - RecoveredField is blank on 157,092 of 157,108 rows and holds two
       values, Quantity and DiscountPercent - the 8 + 8 recovered rows
     - OrderDate, DateOfBirth, JoinDate and LaunchDate are all ISO
       yyyy-mm-dd in the clean files. They were not in the raw files,
       which is what 03_cleaning.ipynb fixed.

   JoinDate being a real DATE matters for one query in particular. The
   cohort block at line 599 of 04_analysis.sql does

       DATEFROMPARTS(YEAR(c.JoinDate), MONTH(c.JoinDate), 1)
       WHERE c.JoinDate IS NOT NULL

   On an NVARCHAR column the 25 blank JoinDates are empty strings, not
   NULLs, so the WHERE clause lets them through and YEAR('') fails the
   whole query. Typed as DATE they are NULL and the filter does what it
   says.
   ===================================================================== */
