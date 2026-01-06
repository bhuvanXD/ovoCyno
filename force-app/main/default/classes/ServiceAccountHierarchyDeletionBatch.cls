public without sharing class ServiceAccountHierarchyDeletionBatch implements Database.Batchable<SObject>, Database.Stateful {

    private Integer totalSAProcessed = 0;

    // --- INNER CLASS: DELETION PLAN ---
    private class DeletionPlan {
        // Bucket 1: Financial & Supply Chain
        public List<SObject> financialRecords = new List<SObject>(); 
        
        // Bucket 2: Standard Children
        public List<SObject> serviceRecords = new List<SObject>();   
        
        // Bucket 3a: Late Children (Leaf Nodes: Actions, Knowledge)
        public List<SObject> lateChildRecords = new List<SObject>();

        // Bucket 3b: Late Parents (Container Nodes: Cases, Agents, Ombudsman Cases)
        public List<SObject> lateParentRecords = new List<SObject>();
        
        // Updates (Self-references) & Files
        public List<SObject> recordsToUpdate = new List<SObject>();
        public Set<Id> entityIdsWithFiles = new Set<Id>();
    }

    // --- START ---
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([SELECT Id FROM Service_Account__c]);
    }

    // --- EXECUTE ---
    public void execute(Database.BatchableContext bc, List<Service_Account__c> scope) {
        Savepoint sp = Database.setSavepoint();

        try {
            totalSAProcessed += scope.size();
            
            // 1. Initialize
            Map<Id, Service_Account__c> saMap = new Map<Id, Service_Account__c>(scope);
            Set<Id> saIds = saMap.keySet();
            DeletionPlan plan = new DeletionPlan();

            // 2. Collection Phase
            collectFinancialAndSupply(saIds, plan);
            collectStandardChildren(saIds, plan);
            
            // Collect Cases & Agents
            List<Case> casesToDelete = collectCaseRecords(saIds, plan);
            Set<Id> caseIds = new Map<Id, Case>(casesToDelete).keySet();
            collectAgentRecords(saIds, caseIds, plan);
            
            // Add Cases to Parent Bucket
            plan.lateParentRecords.addAll(casesToDelete);

            // ==========================================================
            // 3. EXECUTION PHASE
            // ==========================================================
            
            // A. Updates First
            if (!plan.recordsToUpdate.isEmpty()) {
                update deduplicate(plan.recordsToUpdate);
            }

            // B. Delete Files (Clean up files from ALL records before deleting records)
            deleteFiles(plan.entityIdsWithFiles);

            // C. SEQUENTIAL DELETES
            
            if (!plan.financialRecords.isEmpty()) {
                delete deduplicate(plan.financialRecords); // 1. Financials
            }

            if (!plan.serviceRecords.isEmpty()) {
                delete deduplicate(plan.serviceRecords);   // 2. Service Children
            }

            // 3a. Delete Leaf Nodes
            if (!plan.lateChildRecords.isEmpty()) {
                delete deduplicate(plan.lateChildRecords); 
            }

            // 3b. Delete Parent Nodes (Ombudsman Case is here)
            // Deleting the Parent AUTOMATICALLY deletes the Ombudsman Resolution
            if (!plan.lateParentRecords.isEmpty()) {
                delete deduplicate(plan.lateParentRecords); 
            }

            // D. Final Delete: The Scope
            delete scope;

        } catch (Exception ex) {
            Database.rollback(sp);
            System.debug('ERROR: ' + ex.getMessage() + '\nStack Trace: ' + ex.getStackTraceString());
        }
    }
    
    // --- FINISH ---
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
                      'Errors: ' + job.NumberOfErrors;

        mail.setPlainTextBody(body);
        
        if (!Test.isRunningTest()) {
            try {
                Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });
            } catch (Exception e) {
                System.debug('Failed to send email: ' + e.getMessage());
            }
        }
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
        
        List<Supply_Point_Ownership__c> owners = [SELECT Id, Supply_Point__c FROM Supply_Point_Ownership__c WHERE Service_Account__c IN :saIds];
        Set<Id> spIds = new Set<Id>();
        for (Supply_Point_Ownership__c own : owners) {
            if(own.Supply_Point__c != null) spIds.add(own.Supply_Point__c);
        }

        if (!spIds.isEmpty()) {
            plan.financialRecords.addAll([SELECT Id FROM Dispute__c WHERE Supply_Point__c IN :spIds]);
            plan.financialRecords.addAll([SELECT Id FROM Gas_Card__c WHERE Meter_Point_Reference__c IN :spIds]);
        }
        plan.financialRecords.addAll(owners);
        if (!spIds.isEmpty()) plan.financialRecords.addAll([SELECT Id FROM Supply_Point__c WHERE Id IN :spIds]);
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
        List<Case> cases = [SELECT Id, ParentId, Originating_Case__c FROM Case WHERE Service_Account__c IN :saIds];
        Set<Id> caseIds = new Map<Id, Case>(cases).keySet();
        
        if (caseIds.isEmpty()) return cases;

        for (Case c : cases) {
            if ((c.ParentId != null && caseIds.contains(c.ParentId)) || 
                (c.Originating_Case__c != null && caseIds.contains(c.Originating_Case__c))) {
                c.ParentId = null; 
                c.Originating_Case__c = null;
                plan.recordsToUpdate.add(c);
            }
        }
        
        plan.entityIdsWithFiles.addAll(caseIds);
        
        // Children (Explicit Delete)
        plan.lateChildRecords.addAll([SELECT Id FROM Case_Action__c WHERE Case__c IN :caseIds OR Internal_Case__c IN :caseIds]);
        plan.lateChildRecords.addAll([SELECT Id FROM Knowledge_Article_Tracking__c WHERE Case__c IN :caseIds]);

        // Email Files (Implicit Delete)
        List<EmailMessage> caseEmails = [SELECT Id FROM EmailMessage WHERE ParentId IN :caseIds OR RelatedToId IN :caseIds];
        if (!caseEmails.isEmpty()) {
            plan.entityIdsWithFiles.addAll(new Map<Id, EmailMessage>(caseEmails).keySet());
        }

        // --- OMBUDSMAN LOGIC (UPDATED) ---
        List<Ombudsman_Case__c> ombCases = [SELECT Id FROM Ombudsman_Case__c WHERE Case__c IN :caseIds];
        if (!ombCases.isEmpty()) {
            Set<Id> ombIds = new Map<Id, Ombudsman_Case__c>(ombCases).keySet();
            
            // 1. Check Resolutions ONLY to clean up Files (Do NOT add to delete list)
            List<Ombudsman_Resolution__c> resolutions = [SELECT Id FROM Ombudsman_Resolution__c WHERE Ombudsman_Case__c IN :ombIds];
            if(!resolutions.isEmpty()) {
                 plan.entityIdsWithFiles.addAll(new Map<Id, Ombudsman_Resolution__c>(resolutions).keySet());
            }

            // 2. Add Ombudsman Case (Parent) to delete list
            // Deleting this will CASCADE DELETE the resolutions automatically.
            plan.lateParentRecords.addAll(ombCases);
        }
        // ---------------------------------

        return cases;
    }

    private void collectAgentRecords(Set<Id> saIds, Set<Id> caseIds, DeletionPlan plan) {
        List<Agent__c> agents = [SELECT Id FROM Agent__c WHERE Service_Account__c IN :saIds OR Case__c IN :caseIds];
        if (agents.isEmpty()) return;
        
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
        if (input == null || input.isEmpty()) return new List<SObject>();
        Map<Id, SObject> uniqueMap = new Map<Id, SObject>();
        for (SObject obj : input) {
            uniqueMap.put(obj.Id, obj);
        }
        return uniqueMap.values();
    }

    private void deleteFiles(Set<Id> parentIds) {
        if (parentIds == null || parentIds.isEmpty()) return;
        List<ContentDocumentLink> links = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId IN :parentIds];
        if (links.isEmpty()) return;
        
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink cdl : links) docIds.add(cdl.ContentDocumentId);
        
        if (!docIds.isEmpty()) {
            List<ContentDocument> docsToDelete = new List<ContentDocument>();
            for (Id docId : docIds) docsToDelete.add(new ContentDocument(Id = docId));
            delete docsToDelete;
        }
    }
}