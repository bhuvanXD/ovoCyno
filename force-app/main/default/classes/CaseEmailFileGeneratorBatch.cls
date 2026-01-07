/* To run this class:
Database.executeBatch(
    new CaseEmailFileGeneratorBatch(60000),
    200
);
*/
public class CaseEmailFileGeneratorBatch
    implements Database.Batchable<Integer> {

    private Integer totalRecordsToCreate;

    // Constructor
    public CaseEmailFileGeneratorBatch(Integer count) {
        this.totalRecordsToCreate = count;
    }

    public Iterable<Integer> start(Database.BatchableContext bc) {
        List<Integer> scope = new List<Integer>();
        // Create a list of integers to drive the batch execution
        for (Integer i = 1; i <= totalRecordsToCreate; i++) {
            scope.add(i);
        }
        return scope;
    }

    public void execute(Database.BatchableContext bc, List<Integer> scope) {
        
        // ---------------------------------------------------------
        // PRE-REQUISITES
        // ---------------------------------------------------------
        
        // 1. Get Complaint Record Type ID
        Id complaintRT = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Complaints_Unescalated').getRecordTypeId();
		
        // ---------------------------------------------------------
        // STEP 1: Create Main Cases
        // ---------------------------------------------------------
        List<Case> casesToInsert = new List<Case>();
        
        for (Integer i : scope) {
            casesToInsert.add(new Case(
                // Removed Service_Account__c assignment
                RecordTypeId            = complaintRT,
                Complaints_Severity__c  = '2',
                Issue__c                = 'Bulk Issue', 
                Investigation__c        = 'Bulk Inv', 
                Resolution__c           = 'Bulk Res', 
                Outcome__c              = 'Bulk Outcome',
                Origin                  = 'CSAT', 
                Triage_Filter__c        = 'PAYM', 
                Category_Level_Two__c   = 'Collections', 
                Category_Level_Three__c = 'Payment Plans',
                Signposted__c           = false, 
                Subject                 = 'Bulk Generated Case ' + i + ' ' + System.currentTimeMillis()
            ));
        }
        insert casesToInsert;


        // ---------------------------------------------------------
        // STEP 2: Create Agent, Knowledge, and Ombudsman Case
        // ---------------------------------------------------------
        
        List<Agent__c> agentsToInsert = new List<Agent__c>();
        List<Knowledge_Article_Tracking__c> knowledgeToInsert = new List<Knowledge_Article_Tracking__c>();
        List<Ombudsman_Case__c> ombCasesToInsert = new List<Ombudsman_Case__c>();

        for (Case c : casesToInsert) {
            // A. Agent
            agentsToInsert.add(new Agent__c(
                Case__c = c.Id
            ));

            // B. Knowledge Article Tracking
            knowledgeToInsert.add(new Knowledge_Article_Tracking__c(
                Case__c = c.Id
            ));

            // C. Ombudsman Case
            // Name Format: OM + 6 Digits + -01 (e.g., OM123456-01)
            Integer random6Digits = Integer.valueOf((Math.random() * 900000) + 100000);
            String uniqueRef = 'OM' + random6Digits + '-01'; 

            ombCasesToInsert.add(new Ombudsman_Case__c(
                Case__c = c.Id,
                Name    = uniqueRef 
            ));
        }

        insert agentsToInsert;
        insert knowledgeToInsert;
        insert ombCasesToInsert; 


        // ---------------------------------------------------------
        // STEP 3: Create Ombudsman Resolutions
        // ---------------------------------------------------------
        List<Ombudsman_Resolution__c> resolutionsToInsert = new List<Ombudsman_Resolution__c>();
        
        for (Ombudsman_Case__c omb : ombCasesToInsert) {
            resolutionsToInsert.add(new Ombudsman_Resolution__c(
                Ombudsman_Case__c   = omb.Id,     // Link to parent Ombudsman Case
                Resolution_Case__c  = omb.Case__c,// Link to Main Case
                Ombudsman_Remedy__c = 'abc'
            ));
        }
        insert resolutionsToInsert;


        // ---------------------------------------------------------
        // STEP 4: Create EmailMessages
        // ---------------------------------------------------------
        List<EmailMessage> emailsToInsert = new List<EmailMessage>();
        for (Case c : casesToInsert) {
            emailsToInsert.add(new EmailMessage(
                ParentId    = c.Id,
                Subject     = 'Ref: ' + c.Subject,
                FromAddress = 'customer@example.com',
                ToAddress   = 'support@company.com',
                TextBody    = 'Please see attached.',
                Incoming    = true
            ));
        }
        insert emailsToInsert;


        // ---------------------------------------------------------
        // STEP 5: Create ContentVersions (Files)
        // ---------------------------------------------------------
        List<ContentVersion> versionsToInsert = new List<ContentVersion>();
        for (EmailMessage em : emailsToInsert) {
            versionsToInsert.add(new ContentVersion(
                Title          = 'File_For_' + em.Id,
                PathOnClient   = 'Attachment_' + em.Id + '.txt',
                VersionData    = Blob.valueOf('Content for email ' + em.Id),
                IsMajorVersion = true
            ));
        }
        insert versionsToInsert;


        // ---------------------------------------------------------
        // STEP 6: Link Files to EmailMessages
        // ---------------------------------------------------------
        // Re-query to get the generated ContentDocumentId
        List<ContentVersion> insertedVersions =
            [SELECT Id, ContentDocumentId
             FROM ContentVersion
             WHERE Id IN :versionsToInsert];

        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        
        for (Integer i = 0; i < insertedVersions.size(); i++) {
            links.add(new ContentDocumentLink(
                LinkedEntityId    = emailsToInsert[i].Id,
                ContentDocumentId = insertedVersions[i].ContentDocumentId,
                ShareType         = 'V',
                Visibility        = 'AllUsers'
            ));
        }

        insert links;
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('Batch complete. Records created: ' + totalRecordsToCreate);
    }
}