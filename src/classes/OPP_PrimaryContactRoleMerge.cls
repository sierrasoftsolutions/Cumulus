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
* @group Opportunity Contact Role.
* @description Domain Classes for the deletion of duplicate primary OCRs. 
*/

public with sharing class OPP_PrimaryContactRoleMerge {

    @TestVisible private static final String ERROR_MESSAGE = Label.OCRRemovePrimaryDuplicateBatchErrorText;
    @TestVisible private static final String ERROR_CONTEXT = 'Remove Duplicate Primary OCRs';
    @TestVisible private static final String ERROR_SOBJECT = UTIL_Describe.getObjectLabel('Opportunity');

    private String settingsRole;
    private DuplicatePrimaryOCRs duplicatePrimaryOCRs;

    public OPP_PrimaryContactRoleMerge(List<Opportunity> opportunities) {
        settingsRole = UTIL_CustomSettingsFacade.getContactsSettings().npe01__Opportunity_Contact_Role_Default_role__c;
        List<AggregateResult> primaryOCRsAggregateResult = getPrimaryOCRsAggregateResult(opportunities);
        duplicatePrimaryOCRs = new DuplicatePrimaryOCRs(primaryOCRsAggregateResult);
    }

    /*******************************************************************************************************
    * @description Removes the duplicate primary OCRs.
    * @return void.
    ********************************************************************************************************/
    public void run() {
        List<Error__c> errors = new List<Error__c>();
        for (Opportunity opportunityRecord : duplicatePrimaryOCRs.getOpportunities()) {
            OpportunityOCRs opportunityOCRs = new OpportunityOCRs(opportunityRecord);
            OpportunityContactRole primaryContactOCR = opportunityOCRs.getPrimaryContactOCR();

            if (primaryContactOCR == null && opportunityOCRs.containsPrimaryRole(settingsRole) == false) {
                errors.add(createError(opportunityRecord));
                continue;
            }
            if (primaryContactOCR == null && opportunityOCRs.containsPrimaryRole(settingsRole)) {
                List<OpportunityContactRole> ocrsWithSettingsRole = opportunityOCRs.getPrimaryRolesEqual(settingsRole);
                duplicatePrimaryOCRs.makePrimary(ocrsWithSettingsRole[0]);
                continue;
            }
            if (primaryContactOCR != null) {
                duplicatePrimaryOCRs.makePrimary(primaryContactOCR);
            }
        }
        insert errors;
        duplicatePrimaryOCRs.processDML();
    }

    /*******************************************************************************************************
    * @description Gets the Opportunities with duplicate primary OCRs.
    * @param List<Opportunity>. The List of the Opportunities.
    * @return List<AggregateResult>. The Aggregate Result that contains the List of the duplicate primary OCRs.
    ********************************************************************************************************/
    private List<AggregateResult> getPrimaryOCRsAggregateResult(List<Opportunity> opportunities) {
        return [
            SELECT OpportunityId 
            FROM OpportunityContactRole 
            WHERE IsPrimary = true 
            AND OpportunityId IN :opportunities
            GROUP BY OpportunityId 
            HAVING COUNT(Id) > 1
        ];
    }

    /*******************************************************************************************************
    * @description Creates an error log for the Opportunity in the parameter.
    * @param Opportunity. The Opportunity with the error.
    * @return Error__c.
    ********************************************************************************************************/
    private Error__c createError(Opportunity opportunity) {
        return new Error__c(
            Datetime__c = System.now(),
            Full_Message__c = String.format(ERROR_MESSAGE, new List<String>{opportunity.Name}),
            Record_URL__c = URL.getSalesforceBaseUrl().toExternalForm() + '/' + opportunity.Id,
            Context_Type__c = ERROR_CONTEXT,
            Object_Type__c = ERROR_SOBJECT
        );
    }

    /*******************************************************************************************************
    * @description The Duplicate Primary Opportunity Contact Roles Wrapper. It contains the logic that loads  
    * and manages the duplicate Primary OCRs and the related Opportunities.
    ********************************************************************************************************/
    class DuplicatePrimaryOCRs {
        private Map<Id, Opportunity> opportunityRecords;
        private Map<Id, OpportunityContactRole> ocrRecordsToUpdate;
        private Map<Id, OpportunityContactRole> ocrRecordsToDelete;

        /*********************************************************************************************************
        * @description The Constructor of DuplicatePrimaryOCRs.
        * @param List<AggregateResult>. The duplicate primary OCRs Aggregate Result. 
        */
        public DuplicatePrimaryOCRs(List<AggregateResult> primaryOCRsAggregateResult) {
            opportunityRecords = new Map<Id, Opportunity>(loadOpportunities(primaryOCRsAggregateResult));
            ocrRecordsToUpdate = new Map<Id, OpportunityContactRole>();
            ocrRecordsToDelete = new Map<Id, OpportunityContactRole>();
        }

        /*******************************************************************************************************
        * @description Gets the duplicate primary OCRs Opportunities. 
        * @return List<Opportunity> The duplicate primary OCRs Opportunities.
        ********************************************************************************************************/
        public List<Opportunity> getOpportunities() {
            return opportunityRecords.values();
        }

        /*******************************************************************************************************
        * @description Sets the OCR in paramater as Primary OCR.
        * @param OpportunityContactRole. the OCR to set as primary.
        * @return void.
        ********************************************************************************************************/
        public void makePrimary(OpportunityContactRole inputOCR) {
            Opportunity opportunityToUpdate = opportunityRecords.get(inputOCR.OpportunityId);
            for (OpportunityContactRole ocr : opportunityToUpdate.OpportunityContactRoles) {
                // Delete the inputOCR duplicates (same Contact)
                if (ocr.Id != inputOCR.Id && ocr.ContactId == inputOCR.ContactId) {
                    ocrRecordsToDelete.put(ocr.Id, ocr);
                }
                // After a delete of one duplicate Primary OCR, Salesforce update all the OCR IsPrimary to false.
                // So, we need to force the update of the input OCR even if the OCR is already a Primary OCR.
                if (ocr.Id == inputOCR.Id ) {
                    ocr.IsPrimary = true;
                    ocrRecordsToUpdate.put(ocr.Id, ocr);
                }
            }
        }

        /*******************************************************************************************************
        * @description Commits the DMLs (delete/Update OCRs)
        * @return void.
        ********************************************************************************************************/
        public void processDML() {
            delete ocrRecordsToDelete.values();
            update ocrRecordsToUpdate.values();
        }

        /*******************************************************************************************************
        * @description Gets the Opportunities with their related primary OCRs.
        * @param List<AggregateResult>. The duplicate primary OCRs Aggregate Result.
        * @return List<Opportunity>. 
        ********************************************************************************************************/
        private List<Opportunity> loadOpportunities(List<AggregateResult> primaryOCRsAggregateResult) {
            Set<Id> opportunityIds = new Set<Id>();
            for (AggregateResult aggregateResult : primaryOCRsAggregateResult) {
                opportunityIds.add((Id) aggregateResult.get('OpportunityId'));
            }
            return [
                SELECT Name, Primary_Contact__c, (
                    SELECT OpportunityId, ContactId, Role, IsPrimary
                    FROM OpportunityContactRoles
                )
                FROM Opportunity
                WHERE Id IN :opportunityIds
            ];
        }
    }


    /*******************************************************************************************************
    * @description Class that wraps an Opportunity and its related duplicate Primary OCRs.
    ********************************************************************************************************/
    class OpportunityOCRs {
        private Opportunity record;

        /*********************************************************************************************************
        * @description The Constructor of OpportunityOCRs.
        * @param Opportunity. Opportunity with the related primary OCRs.
        */
        public OpportunityOCRs(Opportunity currentOpportunity) {
            record = currentOpportunity;
        }

        /*******************************************************************************************************
        * @description Checks if the Opportunity has a Primary OCR Role equals to the Role in the parameter.
        * @param String OCR Role.
        * @return Boolean.
        ********************************************************************************************************/
        public Boolean containsPrimaryRole(String ocrRole) {
            return getPrimaryRolesEqual(ocrRole).isEmpty() == false;
        }

        /*******************************************************************************************************
        * @description Gets the primary OCRs with role equals to the role in the parameter.
        * @param String OCR Role.
        * @return List<OpportunityContactRole>. The primary OCRs with Role equals to the Role in the parameter.
        ********************************************************************************************************/
        public List<OpportunityContactRole> getPrimaryRolesEqual(String ocrRole) {
            List<OpportunityContactRole> result = new List<OpportunityContactRole>();
            for (OpportunityContactRole ocr : record.OpportunityContactRoles) {
                if (ocr.IsPrimary && ocrRole.equalsIgnoreCase(ocr.Role)) {
                    result.add(ocr);
                }
            }
            return result;
        }

        /*******************************************************************************************************
        * @description Gets the Opportunity Primary Contact OCR.
        * @return OpportunityContactRole. The Opportunity Primary Contact OCR.
        ********************************************************************************************************/
        public OpportunityContactRole getPrimaryContactOCR() {
            for (OpportunityContactRole ocr : record.OpportunityContactRoles) {
                if (ocr.ContactId == record.Primary_Contact__c) {
                    return ocr;
                }
            }
            return null;
        }
    }
}