/* =====================================================================
   00_Load_To_SQLServer.sql
   Contoso Profitability — load the raw CSVs into SQL Server

   Run this once, top to bottom. Nothing else works until it succeeds.
   ---------------------------------------------------------------------
   DESIGN DECISION — every staging column is NVARCHAR.

   That looks wrong until the file contents are taken into account:
   OrderDate has five formats, ShippingDays contains "-" and "unknown",
   Quantity has negatives. Typed on import, SQL Server REJECTS those rows -
   losing the exact defects Step 6 exists to count.

   Load raw -> measure the damage -> then decide the types.
   The stg_ -> clean split is also how real ETL is layered.
   ===================================================================== */


/* ---------- 1. Database ---------------------------------------------- */
IF DB_ID('ContosoRetail') IS NULL
    CREATE DATABASE ContosoRetail;
GO

USE ContosoRetail;
GO


/* ---------- 2. Staging tables, all text ------------------------------ */
DROP TABLE IF EXISTS stg_Fact_Sales;
CREATE TABLE stg_Fact_Sales (
    OrderID          NVARCHAR(50),
    OrderLineID      NVARCHAR(50),
    OrderDate        NVARCHAR(50),
    CustomerID       NVARCHAR(50),
    ProductID        NVARCHAR(50),
    RegionID         NVARCHAR(50),
    ChannelID        NVARCHAR(50),
    Quantity         NVARCHAR(50),
    UnitPrice        NVARCHAR(50),
    DiscountPercent  NVARCHAR(50),
    SalesAmount      NVARCHAR(50),
    CostAmount       NVARCHAR(50),
    ProfitAmount     NVARCHAR(50),
    PaymentMethod    NVARCHAR(100),
    OrderStatus      NVARCHAR(100),
    ReturnFlag       NVARCHAR(50),
    ShippingDays     NVARCHAR(50)
);

DROP TABLE IF EXISTS stg_Dim_Customer;
CREATE TABLE stg_Dim_Customer (
    CustomerID      NVARCHAR(50),
    CustomerName    NVARCHAR(200),
    Gender          NVARCHAR(50),
    DateOfBirth     NVARCHAR(50),
    Age             NVARCHAR(50),
    AgeGroup        NVARCHAR(50),
    Segment         NVARCHAR(100),
    JoinDate        NVARCHAR(50),
    City            NVARCHAR(100),
    State           NVARCHAR(100),
    RegionID        NVARCHAR(50),
    CustomerStatus  NVARCHAR(50)
);

DROP TABLE IF EXISTS stg_Dim_Product;
CREATE TABLE stg_Dim_Product (
    ProductID      NVARCHAR(50),
    ProductName    NVARCHAR(200),
    Category       NVARCHAR(100),
    SubCategory    NVARCHAR(100),
    Brand          NVARCHAR(100),
    LaunchDate     NVARCHAR(50),
    ProductStatus  NVARCHAR(50),
    StandardCost   NVARCHAR(50),
    ListPrice      NVARCHAR(50)
);

DROP TABLE IF EXISTS stg_Dim_Region;
CREATE TABLE stg_Dim_Region (
    RegionID  NVARCHAR(50),
    Region    NVARCHAR(100),
    Zone      NVARCHAR(100),
    State     NVARCHAR(100),
    City      NVARCHAR(100),
    Country   NVARCHAR(100)
);

DROP TABLE IF EXISTS stg_Dim_Date;
CREATE TABLE stg_Dim_Date (
    [Date]           NVARCHAR(50),
    [Year]           NVARCHAR(50),
    Quarter          NVARCHAR(50),
    QuarterNumber    NVARCHAR(50),
    [Month]          NVARCHAR(50),
    MonthNumber      NVARCHAR(50),
    YearMonth        NVARCHAR(50),
    WeekNumber       NVARCHAR(50),
    [Day]            NVARCHAR(50),
    DayName          NVARCHAR(50),
    DayOfWeekNumber  NVARCHAR(50),
    IsWeekend        NVARCHAR(50),
    IsHoliday        NVARCHAR(50)
);

DROP TABLE IF EXISTS stg_Dim_Channel;
CREATE TABLE stg_Dim_Channel (
    ChannelID    NVARCHAR(50),
    Channel      NVARCHAR(100),
    ChannelType  NVARCHAR(50)
);

DROP TABLE IF EXISTS stg_Dim_UserRegion;
CREATE TABLE stg_Dim_UserRegion (
    UserPrincipalName  NVARCHAR(200),
    UserName           NVARCHAR(200),
    RoleName           NVARCHAR(100),
    Zone               NVARCHAR(100),
    Region             NVARCHAR(100),
    RegionID           NVARCHAR(50)
);
GO


/* ---------- 3. Bulk load ---------------------------------------------
   FIRSTROW = 2          skip the header row
   CODEPAGE = '65001'    files are UTF-8; without this any non-ASCII
                         character loads as mojibake
   ROWTERMINATOR '0x0d0a'  these files are CRLF (verified). Using 0x0a
                         would leave a trailing \r on the LAST column of
                         every row — ShippingDays would become "6\r" and
                         TRY_CAST would fail on all 157k rows. A silent,
                         very confusing bug.
   FORMAT = 'CSV'        SQL Server 2017+. Handles quoted fields.
                         On 2016 or older, delete the FORMAT and
                         FIELDQUOTE lines; keep the rest.
   TABLOCK               materially faster on the fact table
   --------------------------------------------------------------------- */



/* ---------- 4. Verify the load ---------------------------------------
   Row counts checked straight after the load. A short table means silent
   truncation, and every number computed afterwards would be wrong.
   --------------------------------------------------------------------- */
SELECT 'stg_Fact_Sales' AS TableName, COUNT(*) AS Loaded, 157116 AS Expected,
       CASE WHEN COUNT(*) = 157116 THEN 'OK' ELSE '*** MISMATCH ***' END AS Result
FROM stg_Fact_Sales
UNION ALL SELECT 'stg_Dim_Customer',   COUNT(*), 8010,
       CASE WHEN COUNT(*) =   8010 THEN 'OK' ELSE '*** MISMATCH ***' END FROM stg_Dim_Customer
UNION ALL SELECT 'stg_Dim_Product',    COUNT(*), 1405,
       CASE WHEN COUNT(*) =   1405 THEN 'OK' ELSE '*** MISMATCH ***' END FROM stg_Dim_Product
UNION ALL SELECT 'stg_Dim_Region',     COUNT(*),   90,
       CASE WHEN COUNT(*) =     90 THEN 'OK' ELSE '*** MISMATCH ***' END FROM stg_Dim_Region
UNION ALL SELECT 'stg_Dim_Date',       COUNT(*), 1461,
       CASE WHEN COUNT(*) =   1461 THEN 'OK' ELSE '*** MISMATCH ***' END FROM stg_Dim_Date
UNION ALL SELECT 'stg_Dim_Channel',    COUNT(*),    4,
       CASE WHEN COUNT(*) =      4 THEN 'OK' ELSE '*** MISMATCH ***' END FROM stg_Dim_Channel
UNION ALL SELECT 'stg_Dim_UserRegion', COUNT(*),  270,
       CASE WHEN COUNT(*) =    270 THEN 'OK' ELSE '*** MISMATCH ***' END FROM stg_Dim_UserRegion;
GO


/* ---------- 5. Confirm no stray carriage returns ----------------------
   If ROWTERMINATOR was wrong, the last column of every row keeps a \r.
   This must return 0. If it returns 157116, fix the terminator and
   reload before going any further.
   --------------------------------------------------------------------- */
SELECT COUNT(*) AS RowsWithTrailingCR
FROM   stg_Fact_Sales
WHERE  ShippingDays LIKE '%' + CHAR(13) + '%';
GO


/* ---------- 6. First look at the raw mess ---------------------------- */
SELECT TOP 100 OrderLineID, OrderDate, Quantity, ShippingDays, OrderStatus, PaymentMethod
FROM   stg_Fact_Sales
WHERE  TRY_CAST(ShippingDays AS INT) IS NULL;
GO


/* =====================================================================
   IF IT FAILS

   "Cannot bulk load ... Operating system error code 5 (Access is denied)"
       The SQL Server SERVICE ACCOUNT opens the file, not the login used
       to run the query.
       Fix: copy the CSVs to a folder the service can read (C:\Data\ is a
       safe bet), or use the Import Wizard below.

   "Bulk load data conversion error ... row 1"
       ROWTERMINATOR. These files are CRLF, so 0x0d0a. Regenerated on
       Linux they would be 0x0a.

   "Incorrect syntax near 'FORMAT'"
       SQL Server 2016 or older. Remove FORMAT and FIELDQUOTE.

   "String or binary data would be truncated"
       A value is longer than its NVARCHAR size. Widen that column.

   FALLBACK — SSMS Import Wizard
       Right-click ContosoRetail > Tasks > Import Flat File.
       CRITICAL: on Modify Columns set EVERY column to nvarchar(200) and
       tick Allow Nulls. The wizard guesses types by default and will
       reject exactly the rows that need keeping.

   FALLBACK 2 — load with Python
       import pandas as pd, sqlalchemy as sa
       eng = sa.create_engine(
           "mssql+pyodbc://@LOCALHOST\\SQLEXPRESS/ContosoRetail"
           "?driver=ODBC+Driver+17+for+SQL+Server&trusted_connection=yes")
       for t in ["Fact_Sales","Dim_Customer","Dim_Product","Dim_Region",
                 "Dim_Date","Dim_Channel","Dim_UserRegion"]:
           pd.read_csv(rf"../data/raw/{t}.csv",
                       dtype=str, keep_default_na=False) \
             .to_sql(f"stg_{t}", eng, if_exists="replace", index=False)

       dtype=str and keep_default_na=False are both essential. Without
       them pandas converts "NA" and "NULL" into real nulls, collapsing the
       seven placeholder forms Step 6 needs to tell apart.
   ===================================================================== */
