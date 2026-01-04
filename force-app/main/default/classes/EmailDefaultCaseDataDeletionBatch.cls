public class EmailDefaultCaseDataDeletionBatch
    implements Database.Batchable<SObject>, Database.Stateful {
 
   
    private Integer totalCasesProcessed = 0;
 
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id
            FROM Case LIMIT 510
        ]);
    }
 
    public void execute(Database.BatchableContext bc, List<Case> scope) {
 
        Savepoint sp = Database.setSavepoint();
 
        try {
            // Track how many Case records this batch processed
            totalCasesProcessed += scope.size();
 
            // 1. Collect Case IDs
            Map<Id, Case> caseMap = new Map<Id, Case>(scope);
            Set<Id> caseIds = caseMap.keySet();
 
            // 2. Collect EmailMessage IDs related to Cases
            Map<Id, EmailMessage> emailMap = new Map<Id, EmailMessage>([
                SELECT Id
                FROM EmailMessage
                WHERE ParentId IN :caseIds
            ]);
            Set<Id> emailIds = emailMap.keySet();
 
            // 3. Collect ContentDocument IDs
            Set<Id> docIds = new Set<Id>();
 
            // 3a. Files linked directly to Cases
            for (ContentDocumentLink cdl : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :caseIds
            ]) {
                docIds.add(cdl.ContentDocumentId);
            }
 
            // 3b. Files linked to EmailMessages
            if (!emailIds.isEmpty()) {
                for (ContentDocumentLink cdl : [
                    SELECT ContentDocumentId
                    FROM ContentDocumentLink
                    WHERE LinkedEntityId IN :emailIds
                ]) {
                    docIds.add(cdl.ContentDocumentId);
                }
            }
 
           
            if (!docIds.isEmpty()) {
                List<ContentDocument> filesToDelete = new List<ContentDocument>();
                for (Id dId : docIds) {
                    filesToDelete.add(new ContentDocument(Id = dId));
                }
                delete filesToDelete;
            }
 
            //NEWLY ADDED
            // 4. Delete Related Custom Objects
            List<SObject> relatedObjectsToDelete = new List<SObject>();
 
            relatedObjectsToDelete.addAll([
                SELECT Id
                FROM Agent__c
                WHERE Case__c IN :caseIds
            ]);
 
            relatedObjectsToDelete.addAll([
                SELECT Id
                FROM Knowledge_Article_Tracking__c
                WHERE Case__c IN :caseIds
            ]);
 
            relatedObjectsToDelete.addAll([
                SELECT Id
                FROM Ombudsman_Resolution__c
                WHERE Resolution_Case__c IN :caseIds
            ]);
 
            if (!relatedObjectsToDelete.isEmpty()) {
                delete relatedObjectsToDelete;
            }
 
            // 5. Delete Cases (EmailMessages cascade)
            delete scope;
 
        } catch (Exception ex) {
            Database.rollback(sp);
            System.debug('ROLLBACK: ' + ex.getMessage());
        }
    }
 
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
        mail.setToAddresses(new String[] { 'bhuvan.sain@cynoteck.com' });
        mail.setSubject('Batch Job Summary: Case & Email Cleanup');
 
        String body =
            'Batch Job Status: ' + job.Status + '\n' +
            'Cases Processed: ' + totalCasesProcessed + '\n' +
            'Batches Processed: ' + job.JobItemsProcessed + '\n' +
            'Total Batches: ' + job.TotalJobItems + '\n' +
            'Number of Errors: ' + job.NumberOfErrors + '\n' +
            'Triggered By: ' + job.CreatedBy.Email;
 
        mail.setPlainTextBody(body);
 
        Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });
 
        System.debug(
            'Batch completed. Cases processed=' + totalCasesProcessed +
            ', JobId=' + job.Id
        );
    }
}