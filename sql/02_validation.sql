/* =====================================================================
   sql/02_validation.sql   —   Step 6 : Validate
   Contoso Profitability
   ---------------------------------------------------------------------
   Nothing in this file changes a row. I can't decide how to handle a
   defect until I know how many rows it touches, so this pass only counts.

   The output is the data-quality log in the README and the report footer.
   Results are recorded under each query as I found them.
   ===================================================================== */

USE ContosoRetail;
GO

/* ---------------------------------------------------------------------
   6.1  Grain — what does one row represent?
   --------------------------------------------------------------------- */
SELECT COUNT(*)                                          AS TotalRows,
       COUNT(DISTINCT OrderLineID)                       AS UniqueLines,
       COUNT(DISTINCT OrderID)                           AS DistinctOrders,
       CAST(COUNT(*) * 1.0 / COUNT(DISTINCT OrderID) AS DECIMAL(5,2)) AS LinesPerOrder
FROM   stg_Fact_Sales;
/*  Result:  157116 | 157116 | 74000 | 2.12

    TotalRows = UniqueLines, so OrderLineID is the key.
    74,000 orders across 157,116 lines — 2.12 products per order.

    I ran this first because every later number depends on the answer, and
    a short row count would mean a truncated load I'd otherwise not notice.

    The 2.12 matters more than it looks: AOV computed on rows instead of
    orders gives Rs 12,180 instead of Rs 25,859. Both look plausible and
    nothing errors, so I wrote the denominator down once and referred back
    to it rather than re-deciding each time.                              */


/* ---------------------------------------------------------------------
   6.2  ShippingDays — asking the data what's broken
   --------------------------------------------------------------------- */
SELECT COALESCE(ShippingDays, '<real NULL>') AS BadValue,
       COUNT(*)                              AS Rows
FROM   stg_Fact_Sales
WHERE  TRY_CAST(ShippingDays AS INT) IS NULL
GROUP  BY COALESCE(ShippingDays, '<real NULL>')
ORDER  BY Rows DESC;
/*  Result — 7 distinct forms, 4,713 rows:
        -            1571
        <real NULL>  1571     empty strings became NULL during BULK INSERT
        Unknown       326
        NA            318
        ?             316
        unknown       306
        N/A           305

    My first draft of this check was
        WHERE ShippingDays IN ('-','?','Unknown')
    which returned 2,213 rows and felt finished. It missed four forms and
    ~2,500 rows, and I'd have hit them later as type-conversion failures
    with no idea where they came from.

    TRY_CAST inverts the question: instead of listing the junk I remember,
    I ask what won't convert. That found forms I hadn't thought of. It's
    the habit I'd keep from this whole project.

    Two different kinds of missing here — a real NULL versus text
    pretending to be data. Same treatment in Step 7, but I had to know
    both existed. COALESCE is in the GROUP BY because NULLs otherwise show
    as a blank row and I couldn't tell NULL from empty string.            */


/* ---------------------------------------------------------------------
   6.3  Text variants — how many values does a column really have?
   --------------------------------------------------------------------- */
SELECT 'Fact_Sales.OrderStatus'   AS Col,
       COUNT(DISTINCT (OrderStatus + '|') COLLATE Latin1_General_BIN2) AS RawDistinct,
       COUNT(DISTINCT UPPER(LTRIM(RTRIM(OrderStatus)))) AS AfterTrimUpper
FROM   stg_Fact_Sales
UNION ALL
SELECT 'Fact_Sales.PaymentMethod',
       COUNT(DISTINCT (PaymentMethod + '|') COLLATE Latin1_General_BIN2),
       COUNT(DISTINCT UPPER(LTRIM(RTRIM(PaymentMethod))))
FROM   stg_Fact_Sales
UNION ALL
SELECT 'Dim_Customer.Gender',
       COUNT(DISTINCT (Gender + '|') COLLATE Latin1_General_BIN2),
       COUNT(DISTINCT UPPER(LTRIM(RTRIM(Gender))))
FROM   stg_Dim_Customer
UNION ALL
SELECT 'Dim_Customer.Segment',
       COUNT(DISTINCT (Segment + '|') COLLATE Latin1_General_BIN2),
       COUNT(DISTINCT UPPER(LTRIM(RTRIM(Segment))))
FROM   stg_Dim_Customer
UNION ALL
SELECT 'Dim_Product.Category',
       COUNT(DISTINCT (Category + '|') COLLATE Latin1_General_BIN2),
       COUNT(DISTINCT UPPER(LTRIM(RTRIM(Category))))
FROM   stg_Dim_Product
UNION ALL
SELECT 'Dim_Product.Brand',
       COUNT(DISTINCT (Brand + '|') COLLATE Latin1_General_BIN2),
       COUNT(DISTINCT UPPER(LTRIM(RTRIM(Brand))))
FROM   stg_Dim_Product;
/*  Result:
        OrderStatus     15 ->  3
        PaymentMethod   36 -> 11
        Gender          20 ->  9
        Segment         20 ->  4
        Category        16 ->  5
        Brand           53 -> 34     (4 of the 34 are placeholders: 30 real brands)

    COLLATION TRAP. The raw count only works because of the
    COLLATE Latin1_General_BIN2 and the '|' appended to each value.
    SQL Server's default collation is case-insensitive, so 'Completed'
    and 'COMPLETED' count as ONE value. And in every collation SQL Server
    ignores trailing spaces when comparing, so 'Completed ' = 'Completed'.
    A plain COUNT(DISTINCT OrderStatus) returns 6 here on a
    case-insensitive database (12 on a case-sensitive one), not 15, and
    hides most of the variants this check exists to find. BIN2 compares bytes;
    the '|' stops trailing spaces from being trimmed off.
    Check the database collation with:
        SELECT DATABASEPROPERTYEX('ContosoRetail', 'Collation');

    Comparing raw distinct against trimmed-and-uppercased distinct gives
    the variant count without reading anything. 36 tokens for 6 payment
    methods is not something I'd have caught by scrolling.

    Gender is the interesting one. Trim and upper takes 20 down to 9, not
    2, because 'M' and 'MALE' are still different strings. That told me
    some columns need a value MAP and others only need a format fix — and
    I'd been about to treat them the same way.                            */

-- Seeing the actual variants, with brackets so whitespace is visible:
SELECT '[' + MIN(OrderStatus) + ']' AS Value, COUNT(*) AS Rows
FROM   stg_Fact_Sales
GROUP  BY (OrderStatus + '|') COLLATE Latin1_General_BIN2
ORDER  BY Rows DESC;
/*  Without the brackets " Completed" and "Completed" are identical on
    screen. I lost twenty minutes to that before adding them.
    The GROUP BY needs the same BIN2 + '|' treatment as above; a plain
    GROUP BY OrderStatus folds the variants together and shows 6 rows.   */


/* ---------------------------------------------------------------------
   6.4  Date formats — which shapes exist, before parsing anything
   --------------------------------------------------------------------- */
SELECT CASE
         WHEN OrderDate LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN 'ISO yyyy-mm-dd'
         WHEN OrderDate LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]' THEN 'NN/NN/yyyy'
         WHEN OrderDate LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]' THEN 'dd-MMM-yyyy'
         WHEN OrderDate LIKE '[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]' THEN 'yyyy/mm/dd'
         ELSE 'other'
       END      AS Shape,
       COUNT(*) AS Rows
FROM   stg_Fact_Sales
GROUP  BY CASE
         WHEN OrderDate LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN 'ISO yyyy-mm-dd'
         WHEN OrderDate LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]' THEN 'NN/NN/yyyy'
         WHEN OrderDate LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]' THEN 'dd-MMM-yyyy'
         WHEN OrderDate LIKE '[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]' THEN 'yyyy/mm/dd'
         ELSE 'other'
       END
ORDER  BY Rows DESC;
/*  Result:
        ISO yyyy-mm-dd  155545
        NN/NN/yyyy         791    contains BOTH dd/mm and mm/dd
        dd-MMM-yyyy        417
        yyyy/mm/dd         363
        non-ISO total    1,571  (1.0%)

    I wrote the CASE expression twice because SQL Server has no ordinal
    GROUP BY — "GROUP BY 1" is Postgres and DuckDB syntax and fails here
    with "Each GROUP BY expression must contain at least one column".
    I'd written it the DuckDB way out of habit. A CTE avoids the
    duplication if the expression gets longer than this.

    Counting first and classifying second mattered: TRY_CONVERT would have
    told me how many were broken but not what shapes existed, and I needed
    the shapes to write the parser.

    One property of this data I only noticed here — the slash formats only
    ever use days above 12. So 13/05/2024 can't be misread as a month, and
    the wrong locale errors rather than silently producing a plausible
    wrong date. That's why I check error counts in Step 7 instead of
    removing errors.                                                      */


/* ---------------------------------------------------------------------
   6.5  Numeric validity
   --------------------------------------------------------------------- */
SELECT SUM(CASE WHEN TRY_CAST(Quantity AS INT) = 0 THEN 1 ELSE 0 END)  AS QtyZero,
       SUM(CASE WHEN TRY_CAST(Quantity AS INT) < 0 THEN 1 ELSE 0 END)  AS QtyNegative,
       MAX(TRY_CAST(Quantity AS INT))                                  AS QtyMax,
       SUM(CASE WHEN TRY_CAST(DiscountPercent AS FLOAT) > 1 THEN 1 ELSE 0 END) AS DiscountOver100
FROM   stg_Fact_Sales;
/*  Result:  8 | 8 | 199 | 8

    TRY_CAST before comparing, not after. These columns are NVARCHAR, so
    string comparison sorts '10' before '2' and WHERE Quantity < '1'
    returns nonsense with no error. I checked that the hard way.

    16 bad quantities and 8 impossible discounts out of 157,116. Small
    enough that excluding them would distort nothing - but first check
    whether the money columns still know the right value. They do: see
    6.5b.                                                                */

SELECT DISTINCT DiscountPercent
FROM   stg_Fact_Sales
WHERE  TRY_CAST(DiscountPercent AS FLOAT) > 1;
/*  Result: 1.10, 1.25, 1.50, 2.00 — all impossible.
    They show up again as pricing-formula breaches in 6.8 because the
    DISCOUNT is wrong, not the money - 6.5b shows the money still implies
    a normal discount. I counted them once, not twice.

    Not whole-number percents either: dividing by 100 misses SalesAmount
    by 3% to 33%.                                                        */


/* ---------------------------------------------------------------------
   6.5b  Can the bad values be recovered from the money?
   --------------------------------------------------------------------- */
SELECT OrderLineID,
       Quantity, UnitPrice, DiscountPercent, SalesAmount,
       CAST(TRY_CAST(SalesAmount AS FLOAT)
            / NULLIF(TRY_CAST(UnitPrice AS FLOAT)
                     * (1 - TRY_CAST(DiscountPercent AS FLOAT)), 0)
            AS DECIMAL(10,3))                                    AS ImpliedQuantity,
       CAST(1 - TRY_CAST(SalesAmount AS FLOAT)
            / NULLIF(TRY_CAST(Quantity AS FLOAT) * TRY_CAST(UnitPrice AS FLOAT), 0)
            AS DECIMAL(10,4))                                    AS ImpliedDiscount,
       OrderStatus, ReturnFlag
FROM   stg_Fact_Sales
WHERE  TRY_CAST(Quantity AS INT) <= 0
   OR  TRY_CAST(DiscountPercent AS FLOAT) > 1
ORDER  BY TRY_CAST(Quantity AS INT), TRY_CAST(DiscountPercent AS FLOAT);
/*  Result:
      Quantity < 0   (8 rows)  negative sales and cost, and the implied
                               quantity disagrees with the recorded one
                               (-1 recorded, -10 implied; -4 vs -2 ...).
                               Nothing consistent to recover -> EXCLUDE.
      Quantity = 0   (8 rows)  positive sales; implied quantity is an exact
                               whole number every time (1 to 8)
                               -> RECOVER.
      Discount > 1   (8 rows)  implied discount is a clean 2-dp value every
                               time (0.04 to 0.26) -> RECOVER.

    None of the 16 bad quantities are returns: all are 'Completed' with
    ReturnFlag FALSE. I had half-expected negative quantities to be
    returns and they are not.

    Exact whole numbers and clean 2-dp values are the evidence. If the
    implied values had come out as 3.47 units, recovery would be guessing
    and exclusion would be the right call.                               */


/* ---------------------------------------------------------------------
   6.6  Referential integrity — the section I got wrong twice
   --------------------------------------------------------------------- */
SELECT 'CustomerID' AS ForeignKey,
       COUNT(*)                     AS OrphanRows,
       COUNT(DISTINCT f.CustomerID) AS OrphanKeys
FROM   stg_Fact_Sales f
WHERE  NOT EXISTS (SELECT 1 FROM stg_Dim_Customer d WHERE d.CustomerID = f.CustomerID)
UNION ALL
SELECT 'ProductID', COUNT(*), COUNT(DISTINCT f.ProductID)
FROM   stg_Fact_Sales f
WHERE  NOT EXISTS (SELECT 1 FROM stg_Dim_Product d WHERE d.ProductID = f.ProductID)
UNION ALL
SELECT 'RegionID', COUNT(*), COUNT(DISTINCT f.RegionID)
FROM   stg_Fact_Sales f
WHERE  NOT EXISTS (SELECT 1 FROM stg_Dim_Region d WHERE d.RegionID = f.RegionID)
UNION ALL
SELECT 'ChannelID', COUNT(*), COUNT(DISTINCT f.ChannelID)
FROM   stg_Fact_Sales f
WHERE  NOT EXISTS (SELECT 1 FROM stg_Dim_Channel d WHERE d.ChannelID = f.ChannelID);
/*  Result:
        CustomerID  15 rows / 6 keys   (C90001-C90006)
        ProductID   15 rows / 6 keys   (P90001-P90006)
        RegionID     4 rows / 2 keys   (R901, R902)
        ChannelID    0 rows / 0 keys

    I tried three versions of this and the first two were wrong.

    Attempt 1 — NOT IN (SELECT CustomerID FROM stg_Dim_Customer).
      Returned zero rows. I nearly recorded "referential integrity is
      clean" and moved on. If the subquery returns even one NULL, NOT IN
      evaluates to UNKNOWN for every row and the result is empty. Silent,
      and it would have propagated into the model.

    Attempt 2 — LEFT JOIN ... WHERE d.CustomerID IS NULL.
      Logically right, but the row count came back higher than the fact
      table. stg_Dim_Customer has 10 duplicate keys and stg_Dim_Product
      has 5, and a LEFT JOIN to a non-unique key multiplies rows. The
      inflation was small enough to look like a real answer.

    Attempt 3 — NOT EXISTS. Short-circuits on the first match, so
      duplicates in the dimension can't affect it. This is the version I
      kept, and the reason I reach for NOT EXISTS by default now.         */

-- The specific IDs, needed for the Step 7 mapping:
SELECT DISTINCT f.CustomerID
FROM   stg_Fact_Sales f
WHERE  NOT EXISTS (SELECT 1 FROM stg_Dim_Customer d WHERE d.CustomerID = f.CustomerID);

-- Reverse direction: a broken security table shows people nothing, or
-- everything, and neither failure announces itself.
SELECT COUNT(*) AS UserRegionOrphans
FROM   stg_Dim_UserRegion u
WHERE  NOT EXISTS (SELECT 1 FROM stg_Dim_Region r WHERE r.RegionID = u.RegionID);
/*  Result: 0                                                            */


/* ---------------------------------------------------------------------
   6.7  Duplicate dimension keys — identical vs conflicting
   --------------------------------------------------------------------- */
WITH k AS (
    SELECT CustomerID,
           COUNT(*) AS RowsPerKey,
           COUNT(DISTINCT CONCAT_WS('|', CustomerName, Gender, DateOfBirth, Age,
                 AgeGroup, Segment, JoinDate, City, State, RegionID, CustomerStatus)) AS Versions
    FROM   stg_Dim_Customer
    GROUP  BY CustomerID
)
SELECT CASE WHEN Versions = 1 THEN 'Identical' ELSE 'Conflicting' END AS DupType,
       COUNT(*)        AS DuplicateKeys,
       SUM(RowsPerKey) AS TotalRowsInvolved
FROM   k
WHERE  RowsPerKey > 1
GROUP  BY CASE WHEN Versions = 1 THEN 'Identical' ELSE 'Conflicting' END;
/*  Result:  Identical 7 keys | Conflicting 3 keys                       */

WITH k AS (
    SELECT ProductID,
           COUNT(*) AS RowsPerKey,
           COUNT(DISTINCT CONCAT_WS('|', ProductName, Category, SubCategory, Brand,
                 LaunchDate, ProductStatus, StandardCost, ListPrice)) AS Versions
    FROM   stg_Dim_Product
    GROUP  BY ProductID
)
SELECT CASE WHEN Versions = 1 THEN 'Identical' ELSE 'Conflicting' END AS DupType,
       COUNT(*) AS DuplicateKeys
FROM   k
WHERE  RowsPerKey > 1
GROUP  BY CASE WHEN Versions = 1 THEN 'Identical' ELSE 'Conflicting' END;
/*  Result:  Identical 3 keys | Conflicting 2 keys

    Comparing COUNT(*) against COUNT(DISTINCT <all columns concatenated>)
    per key splits the two kinds apart. It matters because they need
    opposite fixes: identical rows can be deduplicated with nothing lost,
    conflicting ones need a survivorship rule I have to choose and state.

    SELECT DISTINCT would have removed the 7 identical customer rows and
    left all 3 conflicting ones. The key would still not be unique, the
    relationship would still fail, and I'd have believed it was fixed.    */

-- The conflicting rows themselves — this is what decided the survivorship
-- rule in reference/cleaning_in_sql.sql.
WITH k AS (
    SELECT CustomerID
    FROM   stg_Dim_Customer
    GROUP  BY CustomerID
    HAVING COUNT(*) > 1
       AND COUNT(DISTINCT CONCAT_WS('|', CustomerName, Gender, DateOfBirth, Age,
                 AgeGroup, Segment, JoinDate, City, State, RegionID, CustomerStatus)) > 1
)
SELECT c.*
FROM   stg_Dim_Customer c
JOIN   k ON k.CustomerID = c.CustomerID
ORDER  BY c.CustomerID;


/* ---------------------------------------------------------------------
   6.8  Business rules
   --------------------------------------------------------------------- */
SELECT
   SUM(CASE WHEN ABS( TRY_CAST(SalesAmount AS FLOAT)
                    - ROUND( TRY_CAST(Quantity AS FLOAT)
                           * TRY_CAST(UnitPrice AS FLOAT)
                           * (1 - TRY_CAST(DiscountPercent AS FLOAT)), 2) ) > 0.05
            THEN 1 ELSE 0 END)                                   AS SalesFormulaBreaches,
   SUM(CASE WHEN ABS( (TRY_CAST(SalesAmount AS FLOAT) - TRY_CAST(CostAmount AS FLOAT))
                    -  TRY_CAST(ProfitAmount AS FLOAT) ) > 0.05
            THEN 1 ELSE 0 END)                                   AS ProfitFormulaBreaches,
   SUM(CASE WHEN (CASE WHEN UPPER(LTRIM(RTRIM(OrderStatus))) = 'RETURNED' THEN 1 ELSE 0 END)
               <> (CASE WHEN ReturnFlag = 'TRUE' THEN 1 ELSE 0 END)
            THEN 1 ELSE 0 END)                                   AS ReturnFlagMismatches,
   SUM(CASE WHEN TRY_CAST(ProfitAmount AS FLOAT) < 0 THEN 1 ELSE 0 END) AS NegativeProfitRows,
   COUNT(*)                                                      AS TotalRows
FROM stg_Fact_Sales;
/*  Result:  724 | 349 | 12 | 17425 | 157116

    724 breach the pricing rule and 349 breach the profit rule. Some rows
    breach both, so the union is 1,073 distinct rows — 0.68% of the raw
    table, meaning 99.32% reconciles on both rules.

    That is the only reconciliation figure I quote. After Step 7 drops 24
    rows the clean table shows 700 + 349 = 1,049 distinct breaches out of
    157,092, which is 99.33%. The 0.01 difference is the excluded rows.
    Earlier I had 99.55% in one file and 99.32% in another — 99.55% is the
    pricing rule alone, which is the kinder number and the wrong one.

    The comparison uses a 0.05 tolerance rather than <>. Money is stored
    to two decimals and floating point is inexact, so exact equality
    flagged thousands of rows that were fine. 0.05 sits below the rounding
    unit, so anything above it is a real discrepancy and I can defend the
    threshold if asked.

    The 17,425 negative-profit rows are not errors. They're loss-making
    sales and they're the subject of the whole analysis. Deleting them
    would have deleted the finding — "this row is wrong" and "this row is
    bad news" are different things.                                       */


/* ---------------------------------------------------------------------
   6.9  Missing values in the dimensions
   --------------------------------------------------------------------- */
SELECT 'CustomerName' AS Col,
       SUM(CASE WHEN CustomerName IS NULL
                  OR LTRIM(RTRIM(CustomerName)) IN ('','NA','N/A','NULL','Unknown','unknown','-','?')
                THEN 1 ELSE 0 END) AS MissingRows
FROM stg_Dim_Customer
UNION ALL SELECT 'Gender',   SUM(CASE WHEN Gender   IS NULL OR LTRIM(RTRIM(Gender))   IN ('','NA','N/A','NULL','Unknown','unknown','-','?') THEN 1 ELSE 0 END) FROM stg_Dim_Customer
UNION ALL SELECT 'AgeGroup', SUM(CASE WHEN AgeGroup IS NULL OR LTRIM(RTRIM(AgeGroup)) IN ('','NA','N/A','NULL','Unknown','unknown','-','?') THEN 1 ELSE 0 END) FROM stg_Dim_Customer
UNION ALL SELECT 'JoinDate', SUM(CASE WHEN JoinDate IS NULL OR LTRIM(RTRIM(JoinDate)) IN ('','NA','N/A','NULL','Unknown','unknown','-','?') THEN 1 ELSE 0 END) FROM stg_Dim_Customer
UNION ALL SELECT 'City',     SUM(CASE WHEN City     IS NULL OR LTRIM(RTRIM(City))     IN ('','NA','N/A','NULL','Unknown','unknown','-','?') THEN 1 ELSE 0 END) FROM stg_Dim_Customer
UNION ALL SELECT 'State',    SUM(CASE WHEN State    IS NULL OR LTRIM(RTRIM(State))    IN ('','NA','N/A','NULL','Unknown','unknown','-','?') THEN 1 ELSE 0 END) FROM stg_Dim_Customer
UNION ALL SELECT 'Brand',      SUM(CASE WHEN Brand      IS NULL OR LTRIM(RTRIM(Brand))      IN ('','NA','N/A','NULL','Unknown','unknown','-','?') THEN 1 ELSE 0 END) FROM stg_Dim_Product
UNION ALL SELECT 'LaunchDate', SUM(CASE WHEN LaunchDate IS NULL OR LTRIM(RTRIM(LaunchDate)) IN ('','NA','N/A','NULL','Unknown','unknown','-','?') THEN 1 ELSE 0 END) FROM stg_Dim_Product;
/*  Result: CustomerName 24, Gender 24, AgeGroup 24, JoinDate 24,
            City 16, State 16, Brand 5, LaunchDate 5

    All between 0.2% and 0.4%, so every column stays usable.

    The TRIM inside the check is load-bearing: '   ' is not '', and
    without it I undercounted. The rows I was missing were exactly the
    ones that break joins later.

    DateOfBirth has no missing values, which is why I could recompute Age
    and AgeGroup from it in Step 7 instead of imputing them.

    These counts include all EIGHT placeholder forms. The cleaning step has
    to null all eight too - NULLIF(x, '') alone would leave 'NA', '-' and
    'NULL' sitting in CustomerName, City, State and Brand.               */


/* ---------------------------------------------------------------------
   6.9b  Which order statuses carry money?
   ---------------------------------------------------------------------
   Not a defect - a definition. Revenue = SUM(SalesAmount) silently
   includes whatever statuses are in the table, so before any revenue
   figure is quoted I need to know what each status contributes.
   --------------------------------------------------------------------- */
SELECT UPPER(LTRIM(RTRIM(OrderStatus)))                          AS Status,
       COUNT(*)                                                  AS Lines,
       CAST(SUM(TRY_CAST(SalesAmount  AS FLOAT)) / 1e7 AS DECIMAL(10,2)) AS Revenue_Cr,
       CAST(SUM(TRY_CAST(ProfitAmount AS FLOAT)) / 1e7 AS DECIMAL(10,2)) AS Profit_Cr
FROM   stg_Fact_Sales
GROUP  BY UPPER(LTRIM(RTRIM(OrderStatus)))
ORDER  BY Lines DESC;
/*  Result:
        COMPLETED   146,063   176.83   24.17
        RETURNED      6,219     8.50    1.20
        CANCELLED     4,834     6.02    1.06

    Cancelled orders carry Rs 6.02 Cr of revenue and Rs 1.06 Cr of PROFIT.
    An order that was cancelled earned nothing, so neither number can be
    real. Every money metric in sql/04_analysis.sql therefore uses Completed
    lines only; Returned lines are kept for return-rate metrics.         */


/* =====================================================================
   6.10  The data-quality log — the output of Step 6
   ---------------------------------------------------------------------
   Everything above stacked into one result set. I re-run this after
   Step 7 to show the before/after.
   ===================================================================== */
WITH log_rows AS (
    SELECT 'Fact_Sales' AS TableName, 'ShippingDays' AS ColumnName,
           'Non-numeric placeholder (7 forms)' AS Issue,
           SUM(CASE WHEN TRY_CAST(ShippingDays AS INT) IS NULL THEN 1 ELSE 0 END) AS Rows
    FROM stg_Fact_Sales
    UNION ALL
    SELECT 'Fact_Sales','OrderDate','Non-ISO date format (4 shapes)',
           SUM(CASE WHEN OrderDate NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' THEN 1 ELSE 0 END)
    FROM stg_Fact_Sales
    UNION ALL
    SELECT 'Fact_Sales','PaymentMethod','Missing / placeholder',
           SUM(CASE WHEN PaymentMethod IS NULL
                      OR LTRIM(RTRIM(PaymentMethod)) IN ('','NA','N/A','NULL','Unknown','unknown','-','?')
                    THEN 1 ELSE 0 END)
    FROM stg_Fact_Sales
    UNION ALL
    SELECT 'Fact_Sales','Quantity','Zero or negative',
           SUM(CASE WHEN TRY_CAST(Quantity AS INT) <= 0 THEN 1 ELSE 0 END)
    FROM stg_Fact_Sales
    UNION ALL
    SELECT 'Fact_Sales','DiscountPercent','Above 100% (impossible)',
           SUM(CASE WHEN TRY_CAST(DiscountPercent AS FLOAT) > 1 THEN 1 ELSE 0 END)
    FROM stg_Fact_Sales
    UNION ALL
    SELECT 'Fact_Sales','SalesAmount','Breaks pricing formula',
           SUM(CASE WHEN ABS(TRY_CAST(SalesAmount AS FLOAT)
                    - ROUND(TRY_CAST(Quantity AS FLOAT)*TRY_CAST(UnitPrice AS FLOAT)
                           *(1-TRY_CAST(DiscountPercent AS FLOAT)),2)) > 0.05 THEN 1 ELSE 0 END)
    FROM stg_Fact_Sales
    UNION ALL
    SELECT 'Fact_Sales','ProfitAmount','Breaks Sales - Cost',
           SUM(CASE WHEN ABS((TRY_CAST(SalesAmount AS FLOAT)-TRY_CAST(CostAmount AS FLOAT))
                    - TRY_CAST(ProfitAmount AS FLOAT)) > 0.05 THEN 1 ELSE 0 END)
    FROM stg_Fact_Sales
    UNION ALL
    SELECT 'Fact_Sales','ReturnFlag','Contradicts OrderStatus',
           SUM(CASE WHEN (CASE WHEN UPPER(LTRIM(RTRIM(OrderStatus)))='RETURNED' THEN 1 ELSE 0 END)
                      <> (CASE WHEN ReturnFlag='TRUE' THEN 1 ELSE 0 END) THEN 1 ELSE 0 END)
    FROM stg_Fact_Sales
    UNION ALL
    SELECT 'Fact_Sales','CustomerID','Orphan foreign key', COUNT(*)
    FROM stg_Fact_Sales f WHERE NOT EXISTS (SELECT 1 FROM stg_Dim_Customer d WHERE d.CustomerID=f.CustomerID)
    UNION ALL
    SELECT 'Fact_Sales','ProductID','Orphan foreign key', COUNT(*)
    FROM stg_Fact_Sales f WHERE NOT EXISTS (SELECT 1 FROM stg_Dim_Product d WHERE d.ProductID=f.ProductID)
    UNION ALL
    SELECT 'Fact_Sales','RegionID','Orphan foreign key', COUNT(*)
    FROM stg_Fact_Sales f WHERE NOT EXISTS (SELECT 1 FROM stg_Dim_Region d WHERE d.RegionID=f.RegionID)
    UNION ALL
    SELECT 'Dim_Customer','CustomerID','Duplicate key', COUNT(*)-COUNT(DISTINCT CustomerID) FROM stg_Dim_Customer
    UNION ALL
    SELECT 'Dim_Product','ProductID','Duplicate key', COUNT(*)-COUNT(DISTINCT ProductID) FROM stg_Dim_Product
)
SELECT TableName, ColumnName, Issue, Rows,
       CAST(100.0 * Rows / (SELECT COUNT(*) FROM stg_Fact_Sales) AS DECIMAL(6,3)) AS PctOfFact
FROM   log_rows
WHERE  Rows > 0
ORDER  BY Rows DESC;
/*  Result:
        ShippingDays non-numeric        4713   3.000 %
        OrderDate non-ISO               1571   1.000 %
        PaymentMethod missing           1571   1.000 %
        SalesAmount formula              724   0.461 %
        ProfitAmount formula             349   0.222 %
        Quantity <= 0                     16   0.010 %
        CustomerID orphan                 15
        ProductID orphan                  15
        ReturnFlag mismatch               12
        Dim_Customer duplicate keys       10
        DiscountPercent > 1                8
        Dim_Product duplicate keys         5
        RegionID orphan                    4
   ===================================================================== */


/* =====================================================================
   Step 6 gate met: every issue has a row count. On to reference/cleaning_in_sql.sql,
   where each of these becomes a decision with a reason attached.
   ===================================================================== */
