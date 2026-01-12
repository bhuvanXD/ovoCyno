//Class for deletion of SA and its related records


/*
// === EXECUTE BATCH DELETION ===
ServiceAccountHierarchyDeletionBatch batch = new ServiceAccountHierarchyDeletionBatch();
Database.executeBatch(batch, 50); // Batch size 50 is safe
*/

/**
 * @description Batch class for deletion of Service Accounts and their related records.
 *              Handles large data volumes and complex hierarchies including Cases and Financial records.
 */
public without sharing class ServiceAccountHierarchyDeletionBatch implements Database.Batchable<SObject>, Database.Stateful { // NOPMD

    private Integer totalSAProcessed = 0;
    private List<String> errorLogs = new List<String>();

    // --- INNER CLASS: DELETION PLAN ---
    private class DeletionPlan {
        public List<SObject> financialRecords = new List<SObject>();
        public List<SObject> serviceRecords = new List<SObject>();
        public List<SObject> lateChildRecords = new List<SObject>();
        public List<SObject> lateParentRecords = new List<SObject>();
        public List<SObject> recordsToUpdate = new List<SObject>();
        public Set<Id> entityIdsWithFiles = new Set<Id>();
    }

    // --- START ---
    /**
     * @description Start method to collect the scope of Service Accounts to be deleted.
     * @param bc Database.BatchableContext
     * @return Database.QueryLocator
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Query ALL Service Accounts in the system
        return Database.getQueryLocator([SELECT Id FROM Service_Account__c]); // NOPMD
    }

    // --- EXECUTE ---
    /**
     * @description Execute method to process each batch of Service Accounts.
     *              Collects related records, handles self-references, deletes files, and performs cascading deletion.
     * @param bc Database.BatchableContext
     * @param scope List of Service_Account__c records
     */
    public void execute(Database.BatchableContext bc, List<Service_Account__c> scope) {
        Savepoint sp = Database.setSavepoint();

        try {
            totalSAProcessed += scope.size();

            Map<Id, Service_Account__c> saMap = new Map<Id, Service_Account__c>(scope);
            Set<Id> saIds = saMap.keySet();
            DeletionPlan plan = new DeletionPlan();

            // 1. Collection Phase
            collectFinancialAndSupply(saIds, plan);
            collectStandardChildren(saIds, plan);

            // Collect Cases & Agents (Includes Ombudsman Logic)
            List<Case> casesToDelete = collectCaseRecords(saIds, plan);
            Set<Id> caseIds = new Map<Id, Case>(casesToDelete).keySet();
            collectAgentRecords(saIds, caseIds, plan);

            // Add Cases to Parent Bucket for deletion
            plan.lateParentRecords.addAll(casesToDelete);

            // 2. Execution Phase

            // A. Update Self-References First (Unlock records)
            if (!plan.recordsToUpdate.isEmpty()) {
                update deduplicate(plan.recordsToUpdate);
            }

            // B. Delete Files (NOW INCLUDES OMBUDSMAN CASES)
            deleteFiles(plan.entityIdsWithFiles);

            // C. Sequential Deletes
            if (!plan.financialRecords.isEmpty()) {
                delete deduplicate(plan.financialRecords);
            }
            if (!plan.serviceRecords.isEmpty()) {
                delete deduplicate(plan.serviceRecords);
            }
            if (!plan.lateChildRecords.isEmpty()) {
                delete deduplicate(plan.lateChildRecords);
            }
            if (!plan.lateParentRecords.isEmpty()) {
                delete deduplicate(plan.lateParentRecords);
            }

            // D. Final Delete: The Service Accounts themselves
            delete scope;

        } catch (Exception ex) {
            Database.rollback(sp);
            String errorMsg = 'Batch Error: ' + ex.getMessage() + ' Stack: ' + ex.getStackTraceString();
            errorLogs.add(errorMsg);
            //System.debug(errorMsg);
        }
    }

    // --- FINISH ---
    /**
     * @description Finish method to send an email summary of the batch job execution.
     * @param bc Database.BatchableContext
     */
    public void finish(Database.BatchableContext bc) {
        AsyncApexJob job = [
            SELECT Id,
                   Status,
                   NumberOfErrors,
                   JobItemsProcessed,
                   TotalJobItems,
                   CreatedBy.Email
            FROM AsyncApexJob
            WHERE Id = :bc.getJobId()
        ];

        // Build email
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new String[] { 'bhuv.sain@cynoteck.com' });
        mail.setSubject('Batch Job Summary: Service Account Cleanup');

        String body =
            'Batch Job Status: ' + job.Status + '\n' +
            'Service Accounts Processed: ' + totalSAProcessed + '\n' +
            'Batches Processed: ' + job.JobItemsProcessed + '\n' +
            'Total Batches: ' + job.TotalJobItems + '\n' +
            'Number of Errors: ' + job.NumberOfErrors + '\n' +
            'Triggered By: ' + job.CreatedBy.Email + '\n\n';

        if (!errorLogs.isEmpty()) {
            body += 'Errors Occurred:\n' + String.join(errorLogs, '\n');
        }

        mail.setPlainTextBody(body);

        Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });

        /*System.debug(
            'Batch completed. Service Accounts processed=' + totalSAProcessed +
            ', JobId=' + job.Id
        );*/
    }

    // =================================================================
    //          HELPER METHODS
    // =================================================================

    private void collectFinancialAndSupply(Set<Id> saIds, DeletionPlan plan) {
        List<Direct_Debit_Mandate__c> mandates = [SELECT Id FROM Direct_Debit_Mandate__c WHERE Service_Account__c IN :saIds];
        if (!mandates.isEmpty()) {
            Set<Id> mIds = new Map<Id, Direct_Debit_Mandate__c>(mandates).keySet();
            plan.financialRecords.addAll([SELECT Id FROM Direct_Debit_Subscription__c WHERE Direct_Debit_Mandate__c IN :mIds]);
            plan.financialRecords.addAll(mandates);
        }

        // Direct Service Account Subscriptions (orphaned or direct link)
        plan.financialRecords.addAll([SELECT Id FROM Direct_Debit_Subscription__c WHERE Service_Account__c IN :saIds]);

        List<Supply_Point_Ownership__c> owners = [SELECT Id, Supply_Point__c FROM Supply_Point_Ownership__c WHERE Service_Account__c IN :saIds];
        Set<Id> spIds = new Set<Id>();
        for (Supply_Point_Ownership__c own : owners) {
            if(own.Supply_Point__c != null)
            {
                spIds.add(own.Supply_Point__c);
            }
        }

        if (!spIds.isEmpty()) {
            plan.financialRecords.addAll([SELECT Id FROM Dispute__c WHERE Supply_Point__c IN :spIds]);
            plan.financialRecords.addAll([SELECT Id FROM Gas_Card__c WHERE Meter_Point_Reference__c IN :spIds]);
        }
        plan.financialRecords.addAll(owners);
        if (!spIds.isEmpty())
        {
            plan.financialRecords.addAll([SELECT Id FROM Supply_Point__c WHERE Id IN :spIds]);
        }
    }

    private void collectStandardChildren(Set<Id> saIds, DeletionPlan plan) {
        plan.serviceRecords.addAll([SELECT Id FROM Addon__c WHERE Service_Account__c IN :saIds]);
        plan.serviceRecords.addAll([SELECT Id FROM Communication__c WHERE Service_Account__c IN :saIds]);
        plan.serviceRecords.addAll([SELECT Id FROM Contact_Permission__c WHERE Service_Account__c IN :saIds]);
        plan.serviceRecords.addAll([SELECT Id FROM SSE_Migration_Flags__c WHERE Service_Account__c IN :saIds]);
        plan.serviceRecords.addAll([SELECT Id FROM SSE_Migration_Reference__c WHERE Service_Account__c IN :saIds]);
        plan.serviceRecords.addAll([SELECT Id FROM Gas_Card__c WHERE Service_Account__c IN :saIds AND Meter_Point_Reference__c = NULL]);
    }

    private List<Case> collectCaseRecords(Set<Id> saIds, DeletionPlan plan) {
        // 1. Initial Scope (Directly on Service Account)
        List<Case> cases = [SELECT Id, ParentId, Originating_Case__c FROM Case WHERE Service_Account__c IN :saIds];
        Set<Id> caseIds = new Map<Id, Case>(cases).keySet();

        if (caseIds.isEmpty())
        {
            return cases;
        }

        // 2. Expand Scope (Parents and Children)
        Set<Id> relatedIdsToFetch = new Set<Id>();
        for (Case c : cases) {
            if (c.ParentId != null && !caseIds.contains(c.ParentId)) {
                relatedIdsToFetch.add(c.ParentId);
            }
            if (c.Originating_Case__c != null && !caseIds.contains(c.Originating_Case__c)) {
                relatedIdsToFetch.add(c.Originating_Case__c);
            }
        }

        // Query: Pick up Parents (by Id) AND Children (by ParentId/Originating)
        List<Case> relatedCases = [
            SELECT Id, ParentId, Originating_Case__c
            FROM Case
            WHERE (Id IN :relatedIdsToFetch)
               OR (ParentId IN :caseIds)
               OR (Originating_Case__c IN :caseIds)
        ];

        // Merge, ensuring no duplicates
        for (Case c : relatedCases) {
            if (!caseIds.contains(c.Id)) {
                cases.add(c);
                caseIds.add(c.Id);
            }
        }

        // 3. Process Logic
        processCaseSelfReferences(cases, caseIds, plan);

        // 1. Add CASES to file cleanup
        plan.entityIdsWithFiles.addAll(caseIds);

        collectCaseFiles(caseIds, plan);
        collectOmbudsmanInfo(caseIds, plan);

        return cases;
    }

    private void processCaseSelfReferences(List<Case> cases, Set<Id> caseIds, DeletionPlan plan) {
        for (Case c : cases) {
            if ((c.ParentId != null && caseIds.contains(c.ParentId)) ||
                (c.Originating_Case__c != null && caseIds.contains(c.Originating_Case__c))) {
                //c.ParentId = null;
                //c.Originating_Case__c = null;
                plan.recordsToUpdate.add(c);
            }
        }
    }

    private void collectCaseFiles(Set<Id> caseIds, DeletionPlan plan) {
        // Case Children
        plan.lateChildRecords.addAll([SELECT Id FROM Case_Action__c WHERE Case__c IN :caseIds OR Internal_Case__c IN :caseIds]);
        plan.lateChildRecords.addAll([SELECT Id FROM Knowledge_Article_Tracking__c WHERE Case__c IN :caseIds]);

        // Email Files
        List<EmailMessage> caseEmails = [SELECT Id FROM EmailMessage WHERE ParentId IN :caseIds OR RelatedToId IN :caseIds];
        if (!caseEmails.isEmpty()) {
            plan.entityIdsWithFiles.addAll(new Map<Id, EmailMessage>(caseEmails).keySet());
        }
    }

    private void collectOmbudsmanInfo(Set<Id> caseIds, DeletionPlan plan) {
        // --- OMBUDSMAN LOGIC ---
        List<Ombudsman_Case__c> ombCases = [SELECT Id FROM Ombudsman_Case__c WHERE Case__c IN :caseIds];
        if (!ombCases.isEmpty()) {
            Set<Id> ombIds = new Map<Id, Ombudsman_Case__c>(ombCases).keySet();
            // FIX: Add Ombudsman Cases themselves to file cleanup list
            plan.entityIdsWithFiles.addAll(ombIds);

            // Check Resolutions for files too
            List<Ombudsman_Resolution__c> resolutions = [SELECT Id FROM Ombudsman_Resolution__c WHERE Ombudsman_Case__c IN :ombIds];
            if(!resolutions.isEmpty()) {
                 plan.entityIdsWithFiles.addAll(new Map<Id, Ombudsman_Resolution__c>(resolutions).keySet());
            }

            // Add Ombudsman Case to parent delete list (Resolutions cascade automatically)
            plan.lateParentRecords.addAll(ombCases);
        }
    }

    private void collectAgentRecords(Set<Id> saIds, Set<Id> caseIds, DeletionPlan plan) {
        List<Agent__c> agents = [SELECT Id FROM Agent__c WHERE Service_Account__c IN :saIds OR Case__c IN :caseIds];
        if (agents.isEmpty())
        {
            return;
        }
        Set<Id> agentIds = new Map<Id, Agent__c>(agents).keySet();
        List<Agent_Action__c> actions = [SELECT Id FROM Agent_Action__c WHERE Agent__c IN :agentIds];
        Set<Id> actionIds = new Map<Id, Agent_Action__c>(actions).keySet();

        List<EmailMessage> allEmails = [SELECT Id FROM EmailMessage WHERE RelatedToId IN :agentIds OR RelatedToId IN :actionIds];
        if (!allEmails.isEmpty()) {
            plan.entityIdsWithFiles.addAll(new Map<Id, EmailMessage>(allEmails).keySet());
        }

        plan.lateChildRecords.addAll(actions);
        plan.lateParentRecords.addAll(agents);
    }

    private List<SObject> deduplicate(List<SObject> input) {
        if (input == null || input.isEmpty())
        {
            return new List<SObject>();
        }
        Map<Id, SObject> uniqueMap = new Map<Id, SObject>();
        for (SObject obj : input)
        {
            uniqueMap.put(obj.Id, obj);
        }
        return uniqueMap.values();
    }

    private void deleteFiles(Set<Id> parentIds) {
        if (parentIds == null || parentIds.isEmpty())
        {
            return;
        }

        List<ContentDocumentLink> links = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId IN :parentIds];
        if (links.isEmpty())
        {
            return;
        }
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink cdl : links)
        {
            docIds.add(cdl.ContentDocumentId);
        }

        if (!docIds.isEmpty()){
            List<ContentDocument> docsToDelete = new List<ContentDocument>();
            for (Id docId : docIds)
            {
                docsToDelete.add(new ContentDocument(Id = docId));
            }

            // Delete files
            Database.delete(docsToDelete, false);
        }
    }
}