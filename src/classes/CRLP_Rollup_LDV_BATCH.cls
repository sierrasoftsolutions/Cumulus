/*
    Copyright (c) 2018, Salesforce.org
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Salesforce.org nor the names of
      its contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/
/**
* @author Salesforce.org
* @date 2018
* @group Rollups
* @group-content ../../ApexDocContent/Rollups2.htm
* @description Customizable Rollups Batch for LDV-type Rollups where the detail object has to be the primary object
*  queried in the batch job. Rollups are kept in a stateful collection of CRLP_Rollup instances to allow a rollup
*  for any given parent Account/Contact/GAU to be carried over multiple batch iterations. Generally this job is run
*  with a higher batch size than the standard CRLP_Rollup_BATCH job.
*/
public class CRLP_Rollup_LDV_BATCH extends CRLP_AbstractRollup_BATCH
        implements Database.Batchable<SObject>, Database.Stateful {

    /*******************************************************************************************************
    * @description Constructs the class, sets the properties
    */
    public CRLP_Rollup_LDV_BATCH(SObjectType objType) {
        super(objType);
        this.isLdvBatchJob = true;
    }

    /*******************************************************************************************************
    * @description Constructs the class, sets the properties
    */
    public CRLP_Rollup_LDV_BATCH(List<Id> recordIds) {
        super(recordIds);
        this.isLdvBatchJob = true;
    }

    /*******************************************************************************************************
    * @description Build a query of Detail records based on the specified Summary Object Type.
    * @param bc BatchableContext passed by the system call
    * @return database.Querylocator
    */
    public database.Querylocator start(Database.BatchableContext bc) {
        Integer maxRelatedOppsForNonLDVMode = CRLP_Rollup_SVC.getMaxRelatedOppsForNonLDVMode();
        String query;

        try {
            // Build a query string for the specified Summary object.
            SObjectType detailObjectType;
            String keyField;
            // Not including OppPayment as the child object because including the sub-query in an LDV org
            // may cause a cpu time out issue.
            List<SObjectType> childObjects = new List<SObjectType>();
            if (this.summaryObjectType == General_Accounting_Unit__c.SObjectType) {
                detailObjectType = Allocation__c.SObjectType;
                keyField = SObjectType.Allocation__c.fields.General_Accounting_Unit__c.getName();
                this.jobType = CRLP_RollupProcessingOptions.RollupType.GAU;

            } else if (this.summaryObjectType == Account.SObjectType) {
                detailObjectType = Opportunity.SObjectType;
                keyField = SObjectType.Opportunity.fields.AccountId.getName();
                this.jobType = CRLP_RollupProcessingOptions.RollupType.AccountHardCredit;

            } else if (this.summaryObjectType == Contact.SObjectType) {
                detailObjectType = Opportunity.SObjectType;
                keyField = SObjectType.Opportunity.fields.Primary_Contact__c.getName();
                this.jobType = CRLP_RollupProcessingOptions.RollupType.ContactHardCredit;

            }
            query = CRLP_Query_SEL.buildDetailObjectQueryForRollup(detailObjectType, childObjects);

            this.statefulCacheOfRollupsToBeProcessed.put(this.summaryObjectType,
                    CRLP_Rollup_SEL.getRollupDefinitionsToUse(this.jobType, this.jobFilter));

            List<String> whereClauses = new List<String>();
            // Add necessary filters to limit the LDV batch job to only the records that should be processed as LDV
            if (detailObjectType == Opportunity.SObjectType) {
                whereClauses.add('Account.' + SObjectType.Account.fields.Number_of_Opportunities__c.getName() + ' >= :maxRelatedOppsForNonLDVMode');
            }

            // Exclude Organization Donations from Contact Hard Credit rollups (where Opp.Account.SYSTEM_IsIndividual=false)
            if (this.summaryObjectType == Contact.SObjectType) {
                whereClauses.add('Account.npe01__SYSTEMIsIndividual__c != false');
            }

            if (this.recordIds != null && this.recordIds.size() > 0) {
                whereClauses.add(keyField + ' IN :recordIds');
            }

            // Identify a common filter that can be applied to the main query to reduce the number of records queried
            String addlFilter = CRLP_Query_SEL.buildCommonQueryFilterOnOpportunity(this.summaryObjectType, detailObjectType,
                    this.statefulCacheOfRollupsToBeProcessed.get(this.summaryObjectType));
            if (!String.isEmpty(addlFilter)) {
                whereClauses.add(addlFilter);
            }

            if (!whereClauses.isEmpty()) {
                query += ' WHERE ' + String.join(whereClauses, ' AND ');
            }
            query += ' ORDER BY ' + keyField + ', CreatedDate ASC';

            if (CRLP_Rollup_SVC.hasActiveRollupsForSObject(this.summaryObjectType) == false) {
                // If there are no active rollups for the object type, then force the query to return zero records.
                // This is needed because can't return null as a valid iterator.
                query += ' LIMIT 0';
            }

            UTIL_Debug.debug(LoggingLevel.WARN, '>> LDV Batch Query =' + query);

            return Database.getQueryLocator(query);

        } catch (Exception ex) {
            // TODO Not 100% sure we want to keep this, but for now it's needed to capture any unexpected errors in the processing logic
            ex.setMessage(ex.getMessage() + '\n\nQuery:\n' + query);
            ERR_Handler.processError(ex, ERR_Handler_API.Context.CRLP);
        }

        return Database.getQueryLocator([SELECT Id FROM Account LIMIT 0]); // return a generic empty data set rather than null
    }

    /*******************************************************************************************************
    * @description Handle each group of Detail records to roll-up (i.e., LDV mode). A Stateful collection of
    * CRLP_Rollup instances is used to accumulate the rolled up values by Parent Id across multiple calls to this
    * exection() method with more and more detailsRecords for the same parent.
    * @param bc BatchableContext passed by the system call
    * @param scope List of Detail (Allocation or Opportunity) records
    */
    public void execute(Database.BatchableContext bc, List<SObject> detailRecords) {

        this.batchIteration++;

        try {
            // Build the processing options instance
            CRLP_RollupProcessingOptions.ProcessingOptions options = initOptionsInstance();

            Id lastParentIdProcessed = null; // reset the value

            Id firstParentId = (Id)detailRecords[0].get(options.parentKeyField);
            Id lastParentId = (Id)detailRecords[detailRecords.size()-1].get(options.parentKeyField);

            // For the GAU object, strip out any detail records where the key field is NULL. This is better
            // handled here in the Execute() method than in the query to ensure proper SOQL selectivity.
            detailRecords = applyPostQueryLocatorFilters(detailRecords);

            // Map of Payment Child details by parent Opportunity (this job only handles Opportunity or Allocation
            // as the primary queryLocator).
            Map<Id, List<npe01__OppPayment__c>> paymentsByOpp = new Map<Id, List<npe01__OppPayment__c>>();

            // If the detail object is Opportunity AND there are payment rollups for the parent object
            // these need to be queried outside of the main batch job query due to a current known issue with
            // sub-queries on large objects.
            if (!detailRecords.isEmpty() && options.detailObjType == Opportunity.SObjectType &&
                    CRLP_Rollup_SVC.hasActivePaymentRollupsForSObject(this.summaryObjectType)) {

                // build a list of all the detail record Id's to use for retrieving the child payment records
                // for each Opportunity (detail).
                Set<Id> detailIds = new Map<Id,SObject>(detailRecords).keySet();

                String paymentsQuery = CRLP_Query_SEL.buildObjectQueryForRollup(npe01__OppPayment__c.SObjectType) +
                        ' WHERE npe01__Opportunity__c IN :detailIds ORDER BY npe01__Opportunity__c, CreatedDate ASC';

                for (npe01__OppPayment__c pmt : database.query(paymentsQuery)) {
                    if (!paymentsByOpp.containsKey(pmt.npe01__Opportunity__c)) {
                        paymentsByOpp.put(pmt.npe01__Opportunity__c, new List<npe01__OppPayment__c>());
                    }
                    paymentsByOpp.get(pmt.npe01__Opportunity__c).add(pmt);
                }
            }

            // Get all parent records to be processed by this batch iteration
            List<Id> parentIds = getUniqueParentIds(this.summaryObjectType, detailRecords, options.parentKeyField);

            // Get the Summary (target) records for the current set of Detail Records
            String soql = CRLP_Query_SEL.buildObjectQueryForRollup(options.parentObjType) + ' WHERE Id IN :parentIds ORDER BY Id';

            // Resequence the Parent (Summary) records to be in the exact order of the detail records
            // using the defined parent Id
            List<SObject> summaryRecords = queryAndSequenceSummaryRecords(parentIds, soql);

            // Pass only the specific stateful data for the parents that are actually referenced in the
            // current data scope to the processing class to avoid taking up additional heap size with
            // cloned data.
            options.setMapOfRollupsByParentId(this.statefulRollupsById, parentIds);
            options.setMapOfProcessedOppIdsByAccountId(this.statefulMapOfOppIdsByAcct, parentIds);

            // Call the method to do the actual rollups. This returns only records that require updating
            List<SObject> updatedRecords = CRLP_RollupProcessor_SVC.startRollupProcess(summaryRecords, detailRecords, paymentsByOpp, options);

            // Save Rollups collection and the last parent record id processed in stateful vars
            lastParentIdProcessed = options.getLastParentIdProcessed();
            this.statefulRollupsById.put(firstParentId, options.getUpdatedMapOfRollupsByParentId().get(firstParentId));
            this.statefulRollupsById.put(lastParentId, options.getUpdatedMapOfRollupsByParentId().get(lastParentId));
            if (lastParentIdProcessed != null) {
                this.statefulRollupsById.put(lastParentIdProcessed, options.getUpdatedMapOfRollupsByParentId().get(lastParentIdProcessed));
                this.lastBatchIterationByParentId.put(lastParentIdProcessed, this.batchIteration);
            }

            // Track the last time a given ParentId was seen in a batch iteration. This is used to
            // clean out the stateful collection after X number of batch iterations where the parent id
            // is not seen.
            this.lastBatchIterationByParentId.put(firstParentId, this.batchIteration);
            this.lastBatchIterationByParentId.put(lastParentId, this.batchIteration);

            // Remember which batch iteration this parent was last NOT updated
            if (options.lastParentIdRemovedFromUpdatesList == true) {
                this.parentIdsNotCommittedWithBatch.put(lastParentIdProcessed, this.batchIteration);
                this.lastBatchIterationByParentId.put(lastParentIdProcessed, this.batchIteration);
            }

            // Handle dml on the records to be updated
            CRLP_RollupProcessor_SVC.updateChangedRecordsWithLogging(updatedRecords);
            if (updatedRecords != null) {
                this.totalRecordsModified += updatedRecords.size();
                this.totalCommits++;
                // If the record was committed and the Id is in the parentIdsNotCommittedWithBatch collection
                // that tracks the last batch iteration by Id, remove it from that collection now that it's committed.
                for (SObject s : updatedRecords) {
                    if (this.parentIdsNotCommittedWithBatch.containsKey(s.Id)) {
                        this.parentIdsNotCommittedWithBatch.remove(s.Id);
                    }
                }
            }

        } catch (Exception ex) {
            // TODO Not 100% sure we want to keep this, but for now it's needed to capture any unexpected errors in the processing logic
            ex.setMessage(ex.getMessage() + '\n\nRollups State:\n' + CRLP_Debug_UTIL.getCurrentRollupState());
            ERR_Handler.processError(ex, ERR_Handler_API.Context.CRLP);
        }
    }

    /********************************************************************************************************
     * @description Called when all processing is complete for the batch job. Since this job is working from the
     * Detail object, there will be one parent record to finish the update for.
     * Log any captured DML errors.
     */
    public void finish(Database.BatchableContext bc) {

        try {

            // Handle the final parent record in the LDV job
            if (this.parentIdsNotCommittedWithBatch != null && !this.parentIdsNotCommittedWithBatch.isEmpty()) {
                // Build the processing options instance
                CRLP_RollupProcessingOptions.ProcessingOptions options = initOptionsInstance();

                // Get the Summary (target) records for the final record to be processed
                List<Id> parentIds = new List<Id>(this.parentIdsNotCommittedWithBatch.keySet());
                String soql = CRLP_Query_SEL.buildObjectQueryForRollup(options.parentObjType) + ' WHERE Id IN :parentIds';
                List<SObject> parents = database.query(soql);

                // Pass only the specific stateful data for the parents that are actually referenced in the
                // current data scope to the processing class to avoid taking up additional heap size with
                // cloned data.
                options.setMapOfRollupsByParentId(this.statefulRollupsById, parentIds);
                options.setMapOfProcessedOppIdsByAccountId(this.statefulMapOfOppIdsByAcct, parentIds);

                // Call the method to do the actual rollup on this last remaining record, which is basically
                // just to return the updated record
                List<SObject> updatedRecords = new List<SObject>();
                for (SObject parent : parents) {
                    SObject updatedRecord = CRLP_RollupProcessor_SVC.completeRollupForParent(parent, new List<SObject>(),
                            new Map<Id, List<SObject>>(), options);
                    if (updatedRecord != null) {
                        updatedRecords.add(updatedRecord);
                    }
                }

                // Handle dml on the records to be updated
                if (!updatedRecords.isEmpty()) {
                    CRLP_RollupProcessor_SVC.updateChangedRecordsWithLogging(updatedRecords);
                    this.totalRecordsModified += updatedRecords.size();
                    this.totalCommits++;
                }

            }

        } catch (Exception ex) {
            // TODO Not 100% sure we want to keep this, but for now it's needed to capture any unexpected errors in the processing logic
            ERR_Handler.processError(ex, ERR_Handler_API.Context.CRLP);
        }

    }

    /**
     * @description There are cases where the main queryLocator did not filter out certain records to avoid
     * non-selectivity issues that would affect the query performance. In these cases, this method is hard-coded
     * to strip out any detail records from the queried data that will not be rolled up. Initially this only applies
     * to removing records with a null value in Opportunity__c from the Allocation__c object.
     * @param scope List<SObject> from query locator
     * @return updated List<SObject> with the same or less rows as 'scope'
     */
    private List<SObject> applyPostQueryLocatorFilters(List<SObject> scope) {
        Boolean isAllocationsRollup = (this.summaryObjectType == General_Accounting_Unit__c.SObjectType);

        List<SObject> updatedDetailRecords = new List<SObject>();
        for (Integer n = 0, listSize = scope.size(); n < listSize; n++) {
            if (isAllocationsRollup) {
                Allocation__c alloc = (Allocation__c) scope[n];
                if (alloc.Opportunity__c != null) {
                    updatedDetailRecords.add(alloc);
                }
            } else {
                updatedDetailRecords.add(scope[n]);
            }
        }
        return updatedDetailRecords;
    }
}