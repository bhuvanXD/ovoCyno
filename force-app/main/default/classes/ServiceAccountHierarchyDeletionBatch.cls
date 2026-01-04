public without sharing class ServiceAccountHierarchyDeletionBatch implements Database.Batchable<SObject>, Database.Stateful {

    private Integer totalSAProcessed = 0;
    
    // Helper inner class to hold collection results
    private class DeletionPlan {
        public List<SObject> recordsToUpdate = new List<SObject>();
        public List<SObject> earlyRecordsToDelete = new List<SObject>(); // DD, SP, Standard
        public List<SObject> lateRecordsToDelete = new List<SObject>();  // Cases, Agents, etc.
        public Set<Id> entityIdsWithFiles = new Set<Id>();
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id
            FROM Service_Account__c
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Service_Account__c> scope) {
        Savepoint sp = Database.setSavepoint();

        try {
            // Track how many Service_Account__c records this batch processed
            totalSAProcessed += scope.size();

            // 1. Collect Service_Account__c IDs
            Map<Id, Service_Account__c> saMap = new Map<Id, Service_Account__c>(scope);
            Set<Id> saIds = saMap.keySet();

            // Initialize Plan
            DeletionPlan plan = new DeletionPlan();

            // 2. Collection Phase
            
            // Priority 1: Early Deletions (Direct Debits, Standard Children, Supply Points)
            collectDirectDebitRecords(saIds, plan);
            collectStandardChildren(saIds, plan);
            collectSupplyPointRecords(saIds, plan);
            
            // Priority 2: Case/Agent Logic
            // Cases Hierarchy (returns List<Case> so we can delete them AFTER Agents)
            List<Case> casesToDelete = collectCaseRecords(saIds, plan);
            Set<Id> caseIds = new Map<Id, Case>(casesToDelete).keySet();
            
            // Agents Hierarchy
            collectAgentRecords(saIds, caseIds, plan);

            // Add Cases to late deletion plan (AFTER Agents)
            plan.lateRecordsToDelete.addAll(casesToDelete);

            // 3. Execution Phase
            // Note: Restored order to mimic original code (Deletes -> Updates -> More Deletes)
            // This is critical if Early Deletions trigger callouts (must happen before other DMLs)

            // A. Early Deletions
            if (!plan.earlyRecordsToDelete.isEmpty()) {
                delete deduplicate(plan.earlyRecordsToDelete);
            }

            // B. Update Records (e.g. self-referencing cases)
            if (!plan.recordsToUpdate.isEmpty()) {
                update plan.recordsToUpdate;
            }

            // C. Consolidate File Deletion
            deleteFiles(plan.entityIdsWithFiles);

            // D. Late Deletions (Agents, Cases)
            if (!plan.lateRecordsToDelete.isEmpty()) {
                delete deduplicate(plan.lateRecordsToDelete);
            }

            // Finally delete scope
            delete scope;

        } catch (Exception ex) {
            Database.rollback(sp);
            System.debug('ERROR: ' + ex.getMessage() + '\nStack Trace: ' + ex.getStackTraceString());
        }
    }
    
    // Utility to deduplicate list
    private List<SObject> deduplicate(List<SObject> input) {
        List<SObject> uniqueRecords = new List<SObject>();
        Set<Id> seenIds = new Set<Id>();
        for (SObject obj : input) {
            if (!seenIds.contains(obj.Id)) {
                uniqueRecords.add(obj);
                seenIds.add(obj.Id);
            }
        }
        return uniqueRecords;
    }

    // --- Helper Methods ---

    private void collectDirectDebitRecords(Set<Id> saIds, DeletionPlan plan) {
        List<Direct_Debit_Mandate__c> ddMandates = [
            SELECT Id
            FROM Direct_Debit_Mandate__c
            WHERE Service_Account__c IN :saIds
        ];
        
        if (!ddMandates.isEmpty()) {
            Set<Id> ddMandateIds = new Map<Id, Direct_Debit_Mandate__c>(ddMandates).keySet();
            
            // Subscriptions (Children of Mandate)
            List<Direct_Debit_Subscription__c> ddSubs = [
                SELECT Id
                FROM Direct_Debit_Subscription__c
                WHERE Direct_Debit_Mandate__c IN :ddMandateIds
            ];
            plan.earlyRecordsToDelete.addAll(ddSubs);
            
            // Mandates
            plan.earlyRecordsToDelete.addAll(ddMandates);
        }
    }

    private void collectStandardChildren(Set<Id> saIds, DeletionPlan plan) {
        // Collect simple children
        plan.earlyRecordsToDelete.addAll([SELECT Id FROM Addon__c WHERE Service_Account__c IN :saIds]);
        plan.earlyRecordsToDelete.addAll([SELECT Id FROM Archived_Communication__x WHERE Service_Account__c IN :saIds]);
        plan.earlyRecordsToDelete.addAll([SELECT Id FROM Communication__c WHERE Service_Account__c IN :saIds]);
        plan.earlyRecordsToDelete.addAll([SELECT Id FROM Contact_Permission__c WHERE Service_Account__c IN :saIds]);
        plan.earlyRecordsToDelete.addAll([SELECT Id FROM SSE_Migration_Flags__c WHERE Service_Account__c IN :saIds]);
        plan.earlyRecordsToDelete.addAll([SELECT Id FROM SSE_Migration_Reference__c WHERE Service_Account__c IN :saIds]);
        // Gas Cards directly under SA (not via Supply Point)
        plan.earlyRecordsToDelete.addAll([SELECT Id FROM Gas_Card__c WHERE Service_Account__c IN :saIds]);
    }

    private void collectSupplyPointRecords(Set<Id> saIds, DeletionPlan plan) {
        List<Supply_Point_Ownership__c> ownerships = [
            SELECT Id, Supply_Point__c
            FROM Supply_Point_Ownership__c
            WHERE Service_Account__c IN :saIds
        ];
        
        Set<Id> spIds = new Set<Id>();
        for (Supply_Point_Ownership__c own : ownerships) {
            if (own.Supply_Point__c != null) {
                spIds.add(own.Supply_Point__c);
            }
        }

        if (!spIds.isEmpty()) {
            // SP Children
            plan.earlyRecordsToDelete.addAll([SELECT Id FROM Dispute__c WHERE Supply_Point__c IN :spIds]);
            plan.earlyRecordsToDelete.addAll([SELECT Id FROM Gas_Card__c WHERE Meter_Point_Reference__c IN :spIds]);
        }

        // Ownerships
        plan.earlyRecordsToDelete.addAll(ownerships);

        // Supply Points
        if (!spIds.isEmpty()) {
            plan.earlyRecordsToDelete.addAll([SELECT Id FROM Supply_Point__c WHERE Id IN :spIds]);
        }
    }

    private List<Case> collectCaseRecords(Set<Id> saIds, DeletionPlan plan) {
        List<Case> cases = [
            SELECT Id, ParentId, Originating_Case__c
            FROM Case
            WHERE Service_Account__c IN :saIds
        ];
        Map<Id, Case> caseMap = new Map<Id, Case>(cases);
        Set<Id> caseIds = caseMap.keySet();

        if (caseIds.isEmpty()) {
            return cases;
        }

        // 1. Handle Self-References (updates)
        List<Case> casesToUpdate = new List<Case>();
        for (Case c : cases) {
            boolean changed = false;
            // Check if ParentId points to one of the cases being deleted
            if (c.ParentId != null && caseIds.contains(c.ParentId)) {
                c.ParentId = null;
                changed = true;
            }
            // Check if Originating_Case__c points to one of the cases being deleted
            if (c.Originating_Case__c != null && caseIds.contains(c.Originating_Case__c)) {
                c.Originating_Case__c = null;
                changed = true;
            }
            if (changed) {
                casesToUpdate.add(c);
            }
        }
        plan.recordsToUpdate.addAll(casesToUpdate);
        
        // 2. Identify Files on Cases
        plan.entityIdsWithFiles.addAll(caseIds);

        // 3. Ombudsman Cases
        List<Ombudsman_Case__c> ombudsmanCases = [SELECT Id FROM Ombudsman_Case__c WHERE Case__c IN :caseIds];
        Set<Id> ombudsmanIds = new Map<Id, Ombudsman_Case__c>(ombudsmanCases).keySet();
        if (!ombudsmanIds.isEmpty()) {
            plan.entityIdsWithFiles.addAll(ombudsmanIds);
        }
        
        // Collect manual deletes
        plan.lateRecordsToDelete.addAll([SELECT Id FROM Case_Action__c WHERE Case__c IN :caseIds OR Internal_Case__c IN :caseIds]);
        plan.lateRecordsToDelete.addAll([SELECT Id FROM Knowledge_Article_Tracking__c WHERE Case__c IN :caseIds]);
        plan.lateRecordsToDelete.addAll([SELECT Id FROM Ombudsman_Resolution__c WHERE Resolution_Case__c IN :caseIds]);
        
        // 4. Case Emails
        List<EmailMessage> caseEmails = [SELECT Id FROM EmailMessage WHERE ParentId IN :caseIds OR RelatedToId IN :caseIds];
        if (!caseEmails.isEmpty()) {
            Set<Id> emailIds = new Map<Id, EmailMessage>(caseEmails).keySet();
            plan.entityIdsWithFiles.addAll(emailIds); // Files on Emails
            plan.lateRecordsToDelete.addAll(caseEmails);
        }

        return cases;
    }

    private void collectAgentRecords(Set<Id> saIds, Set<Id> caseIds, DeletionPlan plan) {
        List<Agent__c> agents = [
            SELECT Id
            FROM Agent__c
            WHERE Service_Account__c IN :saIds OR Case__c IN :caseIds
        ];
        
        if (agents.isEmpty()) return;
        
        Set<Id> agentIds = new Map<Id, Agent__c>(agents).keySet();
        
        // Agent Actions (Children of Agent)
        List<Agent_Action__c> agentActions = [SELECT Id FROM Agent_Action__c WHERE Agent__c IN :agentIds];
        Set<Id> actionIds = new Map<Id, Agent_Action__c>(agentActions).keySet();
        
        // Agent Action Emails
        List<EmailMessage> actionEmails = [SELECT Id FROM EmailMessage WHERE RelatedToId IN :actionIds];
        if (!actionEmails.isEmpty()) {
            Set<Id> emailIds = new Map<Id, EmailMessage>(actionEmails).keySet();
            plan.entityIdsWithFiles.addAll(emailIds);
            plan.lateRecordsToDelete.addAll(actionEmails);
        }
        
        // Agent Emails
        List<EmailMessage> agentEmails = [SELECT Id FROM EmailMessage WHERE RelatedToId IN :agentIds];
        if (!agentEmails.isEmpty()) {
            Set<Id> agentEmailIds = new Map<Id, EmailMessage>(agentEmails).keySet();
            plan.entityIdsWithFiles.addAll(agentEmailIds);
            plan.lateRecordsToDelete.addAll(agentEmails);
        }
        
        // Add Records to Delete (Child to Parent)
        plan.lateRecordsToDelete.addAll(agentActions);
        plan.lateRecordsToDelete.addAll(agents);
    }
    
    private void deleteFiles(Set<Id> parentIds) {
        if (parentIds == null || parentIds.isEmpty()) return;
        
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId 
            FROM ContentDocumentLink 
            WHERE LinkedEntityId IN :parentIds
        ];
        
        if (links.isEmpty()) return;
        
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink cdl : links) {
            docIds.add(cdl.ContentDocumentId);
        }
        
        if (!docIds.isEmpty()) {
            List<ContentDocument> docsToDelete = new List<ContentDocument>();
            for (Id docId : docIds) {
                docsToDelete.add(new ContentDocument(Id = docId));
            }
            delete docsToDelete;
        }
    }

    public void finish(Database.BatchableContext bc) {
        AsyncApexJob job = [
            SELECT Id, Status, NumberOfErrors, JobItemsProcessed, TotalJobItems, CreatedBy.Email
            FROM AsyncApexJob
            WHERE Id = :bc.getJobId()
        ];
        
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new String[] { 'bhuvan.sain@cynoteck.com' });
        mail.setSubject('Batch Job Summary: Service Account Hierarchy Cleanup');

        String body = 'Batch Job Status: ' + job.Status + '\n' +
                      'Service Accounts Processed: ' + totalSAProcessed + '\n' +
                      'Batches Processed: ' + job.JobItemsProcessed + '\n' +
                      'Total Batches: ' + job.TotalJobItems + '\n' +
                      'Number of Errors: ' + job.NumberOfErrors + '\n' +
                      'Triggered By: ' + job.CreatedBy.Email;

        mail.setPlainTextBody(body);
        
        if (!Test.isRunningTest()) {
            try {
                Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });
            } catch (Exception e) {
                System.debug('Failed to send email: ' + e.getMessage());
            }
        }

        System.debug('Batch completed. Service Accounts processed=' + totalSAProcessed + ', JobId=' + job.Id);
    }
}